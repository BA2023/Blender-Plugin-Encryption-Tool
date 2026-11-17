import warnings
warnings.filterwarnings("ignore")

import argparse
import ast
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import zipfile
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT_DIR / "config" / "versions.json"
OUTPUT_DIR = ROOT_DIR / "output"
WORK_DIR = ROOT_DIR / "work" / "blender_encrypt_tool_work"
COMPILER_DIR = ROOT_DIR / "compiler"


def log(message: str) -> None:
    # 强制在控制台输出时使用 UTF-8 编码，防止被重定向时因为系统默认编码导致乱码
    sys.stdout.buffer.write((message + "\n").encode("utf-8", errors="replace"))
    sys.stdout.buffer.flush()


def load_versions() -> dict:
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))["versions"]


def get_short_path(path: Path) -> str:
    path_str = str(path)
    buffer = ctypes.create_unicode_buffer(32768)
    result = ctypes.windll.kernel32.GetShortPathNameW(path_str, buffer, len(buffer))
    return buffer.value if result else path_str


def is_ascii_path(path: Path | str) -> bool:
    try:
        str(path).encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def create_directory_junction(link_path: Path, target_path: Path) -> None:
    link_path.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["cmd", "/c", "mklink", "/J", str(link_path), str(target_path)],
        capture_output=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("gbk", errors="ignore").strip()
        stdout = result.stdout.decode("gbk", errors="ignore").strip()
        detail = stderr or stdout or "未知错误"
        raise RuntimeError(f"创建 ASCII 中转目录失败：{link_path} -> {target_path}，{detail}")


def resolve_ascii_dir(path: Path, aliases_root: Path, alias_name: str) -> Path:
    resolved = path.resolve()
    short_candidate = Path(get_short_path(resolved))
    if short_candidate.exists() and is_ascii_path(short_candidate):
        return short_candidate

    alias_path = aliases_root / alias_name
    create_directory_junction(alias_path, resolved)
    return alias_path


def ensure_ascii_compiler_cache(source_root: Path) -> Path:
    source_root = source_root.resolve()
    if is_ascii_path(source_root):
        return source_root

    cache_parent = WORK_DIR / "_compiler_cache"
    cache_root = cache_parent / "compiler"
    temp_root = cache_parent / "compiler.tmp"
    source_version_file = source_root / "version_info.txt"
    cached_version_file = cache_root / "version_info.txt"
    source_version = source_version_file.read_text(encoding="utf-8", errors="ignore") if source_version_file.exists() else ""
    cached_version = cached_version_file.read_text(encoding="utf-8", errors="ignore") if cached_version_file.exists() else ""

    cache_ready = (
        cache_root.exists()
        and (cache_root / "bin" / "gcc.exe").exists()
        and any((cache_root / "libexec").glob("gcc/*/*/cc1.exe"))
        and cached_version == source_version
    )
    log(f"DEBUG: cache_ready={cache_ready}")
    if cache_ready:
        if temp_root.exists():
            shutil.rmtree(temp_root, ignore_errors=True)
        return cache_root

    cache_parent.mkdir(parents=True, exist_ok=True)
    try:
        if temp_root.exists():
            shutil.rmtree(temp_root, ignore_errors=True)
        log(f"DEBUG: copying {source_root} to {temp_root}")
        shutil.copytree(source_root, temp_root)
        log(f"DEBUG: copy done")
        if cache_root.exists():
            shutil.rmtree(cache_root, ignore_errors=True)
        temp_root.rename(cache_root)
        log(f"DEBUG: rename done")
    except Exception as e:
        log(f"DEBUG ERROR in cache: {e}")
        raise
    return cache_root


def resolve_portable_compiler() -> dict[str, Path]:
    gcc_path = COMPILER_DIR / "bin" / "gcc.exe"
    gxx_path = COMPILER_DIR / "bin" / "g++.exe"
    cc1_candidates = sorted((COMPILER_DIR / "libexec").glob("gcc/*/*/cc1.exe"))

    if not gcc_path.exists():
        raise FileNotFoundError(f"未找到内置编译器：{gcc_path}")
    if not gxx_path.exists():
        raise FileNotFoundError(f"未找到内置编译器：{gxx_path}")
    if not cc1_candidates:
        raise FileNotFoundError(f"未找到 GCC 内部组件 cc1.exe，请检查编译器目录是否完整：{COMPILER_DIR}")

    return {
        "root": COMPILER_DIR,
        "gcc": gcc_path,
        "gxx": gxx_path,
        "cc1": cc1_candidates[0],
        "bin": gcc_path.parent,
    }


def sanitize_module_name(raw_name: str) -> str:
    value = re.sub(r"\W+", "_", raw_name)
    value = re.sub(r"_+", "_", value).strip("_")
    if not value:
        value = "addon_package"
    if value[0].isdigit():
        value = f"addon_{value}"
    return value


def extract_bl_info_literal(source_text: str) -> str:
    tree = ast.parse(source_text)
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == "bl_info":
                return ast.unparse(node.value)
    raise ValueError("源码中未找到顶层 bl_info 字典。")


def build_shell_source(source_text: str, core_module_name: str) -> tuple[str, list[str]]:
    bl_info_literal = extract_bl_info_literal(source_text)
    patched_callbacks = [
        "update_camera_parameters",
        "update_camera_parameters_spread",
        "update_camera_parameters_rotation",
        "update_resolution",
        "update_adjustment_mode",
        "render_complete_handler",
        "render_cancel_handler",
    ]
    shell_source = textwrap.dedent(
        f'''
        """Thin Blender add-on wrapper for the compiled core module."""

        import importlib

        import bpy


        # Blender addon discovery expects a literal bl_info dict in __init__.py.
        bl_info = {bl_info_literal}


        def _make_persistent_wrapper(callback):
            @bpy.app.handlers.persistent
            def wrapper(scene=None, *args):
                return callback(scene, *args)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_update_wrapper(callback):
            def wrapper(self, context):
                return callback(self, context)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_execute_wrapper(callback):
            def wrapper(self, context):
                return callback(self, context)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_draw_wrapper(callback):
            def wrapper(self, context):
                return callback(self, context)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_invoke_wrapper(callback):
            def wrapper(self, context, event):
                return callback(self, context, event)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_modal_wrapper(callback):
            def wrapper(self, context, event):
                return callback(self, context, event)

            wrapper.__name__ = callback.__name__
            return wrapper


        def _make_poll_wrapper(callback):
            @classmethod
            def wrapper(cls, context):
                return callback(context)

            wrapper.__name__ = getattr(callback, "__name__", "poll")
            return wrapper


        def _patch_blender_classes(core):
            method_wrappers = {{
                "execute": _make_execute_wrapper,
                "draw": _make_draw_wrapper,
                "invoke": _make_invoke_wrapper,
                "modal": _make_modal_wrapper,
            }}

            for value in vars(core).values():
                if not isinstance(value, type):
                    continue

                for method_name, factory in method_wrappers.items():
                    callback = value.__dict__.get(method_name)
                    if callable(callback):
                        setattr(value, method_name, factory(callback))

                poll_descriptor = value.__dict__.get("poll")
                if isinstance(poll_descriptor, classmethod):
                    setattr(value, "poll", _make_poll_wrapper(getattr(value, "poll")))


        def _patch_core(core):
            if getattr(core, "_jiugongge_persistent_patched", False):
                return core

            _patch_blender_classes(core)

            for callback_name in (
                "update_camera_parameters",
                "update_camera_parameters_spread",
                "update_camera_parameters_rotation",
                "update_resolution",
                "update_adjustment_mode",
            ):
                callback = getattr(core, callback_name, None)
                if callable(callback):
                    setattr(core, callback_name, _make_update_wrapper(callback))

            for handler_name in ("render_complete_handler", "render_cancel_handler"):
                callback = getattr(core, handler_name, None)
                if callable(callback):
                    setattr(core, handler_name, _make_persistent_wrapper(callback))

            core._jiugongge_persistent_patched = True
            return core


        def _load_core():
            try:
                core = importlib.import_module(".{core_module_name}", __package__)
                return _patch_core(core)
            except Exception as exc:
                raise ImportError(
                    f"Failed to load {core_module_name}.pyd. "
                    f"Original error: {{exc}}. "
                    "Build the extension with the same Python version bundled with Blender."
                ) from exc


        def register():
            _load_core().register()


        def unregister():
            _load_core().unregister()
        '''
    ).strip() + "\n"
    return shell_source, patched_callbacks


def _is_persistent_decorator(node: ast.expr) -> bool:
    if isinstance(node, ast.Name):
        return node.id == "persistent"
    if isinstance(node, ast.Attribute):
        return node.attr == "persistent"
    return False


def _is_bpy_props_call(node: ast.AST) -> bool:
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    if not isinstance(func, ast.Attribute):
        return False
    if not isinstance(func.value, ast.Attribute):
        return False
    return isinstance(func.value.value, ast.Name) and func.value.value.id == "bpy" and func.value.attr == "props"


class PersistentStripper(ast.NodeTransformer):
    """Recursively remove Blender persistent decorators from compiled core code."""

    def __init__(self) -> None:
        self.stripped_functions: list[str] = []

    def _strip(self, node: ast.AST) -> ast.AST:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return node

        original_len = len(node.decorator_list)
        node.decorator_list = [
            decorator
            for decorator in node.decorator_list
            if not _is_persistent_decorator(decorator)
        ]
        if len(node.decorator_list) != original_len:
            self.stripped_functions.append(node.name)
        return node

    def visit_FunctionDef(self, node: ast.FunctionDef) -> ast.AST:
        self.generic_visit(node)
        return self._strip(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> ast.AST:
        self.generic_visit(node)
        return self._strip(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> ast.AST:
        self.generic_visit(node)
        if (
            isinstance(node.target, ast.Name)
            and _is_bpy_props_call(node.annotation)
            and node.value is None
            and node.simple == 1
        ):
            return ast.Assign(targets=[node.target], value=node.annotation)
        return node


def build_core_source(source_text: str) -> tuple[str, list[str]]:
    """Strip decorators that only accept pure Python functions.

    The shell module keeps these decorators on Python wrapper functions, while
    the compiled core module must avoid executing them on Cython functions.
    """
    tree = ast.parse(source_text)
    stripper = PersistentStripper()
    tree = stripper.visit(tree)

    ast.fix_missing_locations(tree)
    return ast.unparse(tree) + "\n", stripper.stripped_functions


def build_setup_py(core_module_name: str, python_root: Path, b_flags: list[str]) -> str:
    b_flags_repr = repr(b_flags)
    return textwrap.dedent(
        f"""
        from pathlib import Path
        import sys
        import sysconfig
        from distutils import sysconfig as distutils_sysconfig
        from setuptools import Extension, setup
        from Cython.Build import cythonize

        PYTHON_HOME = Path({str(python_root)!r})
        PYTHON_INCLUDE = PYTHON_HOME / "Include"
        PYTHON_INCLUDE_LOWER = PYTHON_HOME / "include"
        PYTHON_LIBS = PYTHON_HOME / "libs"

        def _prepare_python_paths():
            include_dir = PYTHON_INCLUDE if PYTHON_INCLUDE.exists() else PYTHON_INCLUDE_LOWER
            include_dirs = [str(include_dir)]
            if PYTHON_INCLUDE_LOWER.exists() and PYTHON_INCLUDE_LOWER != include_dir:
                include_dirs.append(str(PYTHON_INCLUDE_LOWER))

            overrides = {{
                "INCLUDEPY": str(include_dir),
                "CONFINCLUDEPY": str(include_dir),
                "LIBDIR": str(PYTHON_LIBS),
                "LIBPL": str(PYTHON_LIBS),
                "base": str(PYTHON_HOME),
                "platbase": str(PYTHON_HOME),
                "installed_base": str(PYTHON_HOME),
                "installed_platbase": str(PYTHON_HOME),
                "prefix": str(PYTHON_HOME),
                "exec_prefix": str(PYTHON_HOME),
                "BINDIR": str(PYTHON_HOME),
            }}

            for module in (sysconfig, distutils_sysconfig):
                config_vars = module.get_config_vars()
                config_vars.update(overrides)
                if getattr(module, "_CONFIG_VARS", None) is not None:
                    module._CONFIG_VARS.update(overrides)
                if getattr(module, "_config_vars", None) is not None:
                    module._config_vars.update(overrides)

            sys.prefix = str(PYTHON_HOME)
            sys.exec_prefix = str(PYTHON_HOME)
            if hasattr(sys, "base_prefix"):
                sys.base_prefix = str(PYTHON_HOME)
            if hasattr(sys, "base_exec_prefix"):
                sys.base_exec_prefix = str(PYTHON_HOME)

            return include_dirs

        include_dirs = _prepare_python_paths()

        ext_modules = [
            Extension(
                name="{core_module_name}",
                sources=["{core_module_name}.py"],
                include_dirs=include_dirs,
                library_dirs=[str(PYTHON_LIBS)],
                extra_compile_args={b_flags_repr},
                extra_link_args={b_flags_repr},
            )
        ]

        setup(
            name="{core_module_name}",
            ext_modules=cythonize(
                ext_modules,
                compiler_directives={{
                    "language_level": 3,
                    "optimize.use_switch": False,
                    "optimize.unpack_method_calls": False,
                    "warn.unreachable": False
                }},
                annotate=False,
            ),
            options={{"build_ext": {{"compiler": "mingw32"}}}},
        )
        """
    ).strip() + "\n"


def find_compiled_binary(work_dir: Path, core_module_name: str) -> Path:
    candidates = sorted(work_dir.glob(f"{core_module_name}*.pyd"))
    if not candidates:
        raise FileNotFoundError(f"未找到编译后的 .pyd 文件: {core_module_name}")
    return candidates[0]


def zip_package(package_dir: Path, output_zip: Path) -> None:
    with zipfile.ZipFile(output_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for file_path in sorted(package_dir.rglob("*")):
            if file_path.is_file():
                zf.write(file_path, arcname=str(file_path.relative_to(package_dir.parent)))


def resolve_python(versions: dict, version: str) -> tuple[str, str]:
    version_info = versions.get(version)
    if not version_info:
        raise ValueError(f"不支持的 Python 版本: {version}")
    python_path = (ROOT_DIR / version_info["python"]).resolve()
    return str(python_path), version_info["tag"]


def run_build(source_file: Path, version: str, output_dir_arg: Path) -> Path:
    versions = load_versions()
    python_exe, py_tag = resolve_python(versions, version)
    compiler_info = resolve_portable_compiler()

    if not Path(python_exe).exists():
        raise FileNotFoundError(f"未找到所选 Python 环境: {python_exe}")
    if not source_file.exists():
        raise FileNotFoundError(f"未找到源脚本: {source_file}")

    addon_package = sanitize_module_name(source_file.stem)
    core_module_name = f"{addon_package}_core"

    log(f"[信息] 源脚本: {source_file}")
    log(f"[信息] 包名: {addon_package}")
    log(f"[信息] 目标版本: Python {version} ({py_tag})")

    source_text = source_file.read_text(encoding="utf-8")
    shell_source, protected_functions = build_shell_source(source_text, core_module_name)
    core_source, stripped_decorators = build_core_source(source_text)

    if not protected_functions:
        log("[警告] 没有找到可保护的顶层函数，将只打包壳层。")
    else:
        log(f"[信息] 已代理 {len(protected_functions)} 个顶层函数到核心模块。")
    if stripped_decorators:
        log(f"[信息] 已在核心模块中跳过 {len(stripped_decorators)} 个 persistent 装饰器。")

    build_root = WORK_DIR / f"{addon_package}_{py_tag}"
    if build_root.exists():
        shutil.rmtree(build_root)
    build_root.mkdir(parents=True, exist_ok=True)

    try:
        aliases_root = build_root / "_ascii_links"
        build_root_ascii = resolve_ascii_dir(build_root, aliases_root, "build")
        python_root_ascii = resolve_ascii_dir(Path(python_exe).parent, aliases_root, f"python_{py_tag}")
        if not is_ascii_path(compiler_info["root"]):
            compiler_cache_root = WORK_DIR / "_compiler_cache" / "compiler"
            if compiler_cache_root.exists():
                log(f"[信息] 使用 ASCII GCC 缓存: {compiler_cache_root}")
            else:
                log("[步骤] 正在初始化 ASCII GCC 缓存，首次运行会稍慢一些...")
        compiler_root_ascii = ensure_ascii_compiler_cache(compiler_info["root"])
        python_run_exe = python_root_ascii / "python.exe"
        compiler_bin = compiler_root_ascii / "bin"
        compiler_gcc = compiler_bin / "gcc.exe"

        if not python_run_exe.exists():
            raise FileNotFoundError(f"ASCII 中转 Python 不存在：{python_run_exe}")
        if not compiler_gcc.exists():
            raise FileNotFoundError(f"ASCII 中转 GCC 不存在：{compiler_gcc}")

        log(f"[信息] 编译器环境: {python_run_exe}")
        log(f"[信息] 内置 GCC: {compiler_gcc}")
        if python_root_ascii.resolve() != Path(python_exe).parent.resolve():
            log(f"[信息] Python ASCII 中转: {python_root_ascii}")
        if compiler_root_ascii.resolve() != compiler_info['root'].resolve():
            log(f"[信息] GCC ASCII 中转: {compiler_root_ascii}")

        core_py_path = build_root / f"{core_module_name}.py"
        core_py_path.write_text(core_source, encoding="utf-8")

        rel_compiler = os.path.relpath(compiler_root_ascii, build_root_ascii).replace("\\", "/")
        b_flags = [
            f"-B{rel_compiler}/lib/gcc/x86_64-w64-mingw32/15.1.0",
            f"-B{rel_compiler}/x86_64-w64-mingw32/bin",
            f"-B{rel_compiler}/x86_64-w64-mingw32/lib",
            f"-B{rel_compiler}/lib",
        ]

        (build_root / "setup.py").write_text(build_setup_py(core_module_name, python_root_ascii, b_flags), encoding="utf-8")

        env = os.environ.copy()
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env["PYTHONUTF8"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONPYCACHEPREFIX"] = str(build_root_ascii / ".pycache")
        env["PYTHONHOME"] = str(python_root_ascii)
        env["PATH"] = os.pathsep.join(
            [
                str(compiler_bin),
                env.get("PATH", ""),
            ]
        )
        env["CC"] = "gcc"
        env["CXX"] = "g++"

        log(f"[信息] 临时构建目录: {build_root}")
        if build_root_ascii.resolve() != build_root.resolve():
            log(f"[信息] 构建目录 ASCII 中转: {build_root_ascii}")
        log("[步骤] 开始编译核心模块...")
        result = subprocess.run(
            [
                str(python_run_exe),
                "setup.py",
                "build_ext",
                "--compiler",
                "mingw32",
                "--inplace",
                "--build-temp",
                "build/temp",
                "--build-lib",
                "build/lib",
            ],
            cwd=build_root_ascii,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError("编译失败，请查看上面的错误输出。")

        compiled_binary = find_compiled_binary(build_root, core_module_name)
        package_dir = build_root / addon_package
        package_dir.mkdir(parents=True, exist_ok=True)
        (package_dir / "__init__.py").write_text(shell_source, encoding="utf-8")

        target_binary_name = f"{core_module_name}{compiled_binary.suffix}"
        shutil.copy2(compiled_binary, package_dir / target_binary_name)

        output_dir_arg.mkdir(parents=True, exist_ok=True)
        output_zip = output_dir_arg / f"{addon_package}_{py_tag}.zip"

        # 防止旧文件被占用导致打包失败
        if output_zip.exists():
            try:
                output_zip.unlink()
            except PermissionError:
                raise RuntimeError(f"无法覆盖输出文件，请先在其他软件（如 Blender 或文件管理器）中关闭或取消选中该文件: {output_zip}")

        zip_package(package_dir, output_zip)

        log("[完成] 打包成功。")
        log(f"[输出] {output_zip}")
        return output_zip
    finally:
        shutil.rmtree(build_root, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Blender 插件混合编译打包器")
    parser.add_argument("--source", required=True, help="待编译的 .py 脚本路径")
    parser.add_argument("--version", required=True, help="Python 版本，例如 3.11")
    parser.add_argument("--output", required=False, help="输出目录路径", default=str(OUTPUT_DIR))
    args = parser.parse_args()

    try:
        output_zip = run_build(Path(args.source).resolve(), args.version, Path(args.output).resolve())
    except Exception as exc:
        log(f"[错误] {exc}")
        return 1

    log(f"[完成] 最终安装包: {output_zip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
