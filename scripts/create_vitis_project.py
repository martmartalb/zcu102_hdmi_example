#!/usr/bin/env python3

import argparse
import os
import shutil
import inspect
import vitis
from hsi import *

# =========================================================
# Command registry
# =========================================================

COMMANDS = {}

def build_command(func):
    """
    Decorator to register CLI commands automatically
    """
    name = func.__name__
    sig = inspect.signature(func)

    COMMANDS[name] = {
        "func": func,
        "signature": sig
    }

    return func


# =========================================================
# Helpers
# =========================================================


def get_processor_from_xsa(xsa):
    print("==> Extracting processor from XSA...")
    hw = HwManager.open_hw_design(xsa)

    for proc in hw.get_cells(hierarchical='true', filter='IP_TYPE==PROCESSOR'):
        if proc.IP_NAME in ["psu_cortexa53", "psv_cortexa72", "ps7_cortexa9"]:
            cpu = proc.IP_NAME + "_0"
            print(f"==> Found processor: {cpu}")
            return cpu

    raise RuntimeError("No supported processor found in XSA")


def get_platform_export_path(workspace, platform_name):
    return os.path.join(
        workspace,
        platform_name,
        "export",
        platform_name,
        f"{platform_name}.xpfm"
    )


# =========================================================
# Commands
# =========================================================

@build_command
def platform(xsa: str, workspace: str, name: str, clean: bool = False):
    xsa = os.path.abspath(xsa)
    workspace = os.path.abspath(workspace)

    print(f"==> Creating platform '{name}'")

    if clean and os.path.exists(workspace):
        shutil.rmtree(workspace)

    os.makedirs(workspace, exist_ok=True)

    cpu = get_processor_from_xsa(xsa)

    client = vitis.create_client()
    client.set_workspace(workspace)

    platform = client.create_platform_component(
        name=name,
        hw_design=xsa,
        os="standalone",
        cpu=cpu
    )

    platform.build()
    print("==> Platform created")


@build_command
def vitis_app(workspace: str, xpfm: str, name: str, src_dir: str):

    workspace = os.path.abspath(workspace)
    src_dir = os.path.abspath(src_dir)
    xpfm = os.path.abspath(xpfm)

    client = vitis.create_client()
    client.set_workspace(workspace)

    # TODO: this is hardcoded, auto get the domain name from platform
    domain_name = "standalone_psu_cortexa53_0"

    app = client.create_app_component(
        name=name,
        platform=xpfm,
        domain=domain_name
    )

    app_src = os.path.join(workspace, name, "src")

    if os.path.exists(app_src):
        shutil.rmtree(app_src)

    shutil.copytree(src_dir, app_src)

    print("==> Building app...")
    app.build()

    print("==> App created successfully!")

# =========================================================
# CLI builder (auto from signature)
# =========================================================

def build_parser():
    parser = argparse.ArgumentParser(description="Vitis CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, meta in COMMANDS.items():
        func = meta["func"]
        sig = meta["signature"]

        sub = subparsers.add_parser(name)

        for param_name, param in sig.parameters.items():
            param_type = param.annotation if param.annotation != inspect._empty else str

            arg_name = f"--{param_name}"

            if param.default == inspect._empty:
                # required argument
                sub.add_argument(arg_name, required=True, type=param_type)
            else:
                if param_type == bool:
                    # boolean flag
                    sub.add_argument(arg_name, action="store_true")
                else:
                    sub.add_argument(arg_name, default=param.default, type=param_type)

        sub.set_defaults(func=func)

    return parser


# =========================================================
# CLI entry point
# =========================================================

def main():
    parser = build_parser()
    args = parser.parse_args()

    cmd = args.func

    # Extract only function arguments
    func_args = {
        k: v for k, v in vars(args).items()
        if k not in ["func", "command"]
    }
    cmd(**func_args)


if __name__ == "__main__":
    main()