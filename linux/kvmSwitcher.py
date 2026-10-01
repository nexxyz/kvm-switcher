#!/usr/bin/env python3
"""Fixed, one-shot Linux KVM Switcher and console entry point."""

import argparse
import json
import os
import sys
import unicodedata
from dataclasses import dataclass, replace
from hashlib import sha256
from pathlib import Path
from typing import Any, List, Optional, Sequence, Tuple


VID = 0x1462
PID = 0x3FA4
INTERFACE_NUMBER = 0
REPORT_LENGTH = 64
REPORT_ID = 0x01
READ_TIMEOUT_MS = 1500


def _frame(payload: bytes) -> bytes:
    return bytes((REPORT_ID,)) + payload + bytes(
        REPORT_LENGTH - 1 - len(payload)
    )


DISPLAY_DP_FRAME = _frame(b"5b00500002\r")
DISPLAY_HDMI1_FRAME = _frame(b"5b00500000\r")
KVM_UPSTREAM_FRAME = _frame(b"5b008>0001\r")
KVM_TYPEC_FRAME = _frame(b"5b008>0002\r")


@dataclass(frozen=True)
class SendResult:
    target: str
    write_count: int
    read_length: int
    read_sha256: Optional[str]
    disconnected: bool


def _invalid(message: str) -> ValueError:
    return ValueError("invalid config: " + message)


def _reject_duplicate_members(pairs: List[Tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON property")
        result[key] = value
    return result


def load_config(path: Path) -> List[Tuple[str, str, str, bool]]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream, object_pairs_hook=_reject_duplicate_members)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise _invalid("cannot read JSON") from exc

    if not isinstance(value, dict) or set(value) != {"targets"}:
        raise _invalid("root must contain only targets")
    targets = value["targets"]
    if not isinstance(targets, list) or not targets:
        raise _invalid("targets must be a nonempty list")

    allowed = {"name", "input", "kvm", "hotkey", "default"}
    names = set()
    result = []
    for index, target in enumerate(targets):
        if not isinstance(target, dict):
            raise _invalid(f"target {index} must be an object")
        if set(target) - allowed or not {"name", "input", "kvm"}.issubset(target):
            raise _invalid(f"target {index} has invalid properties")

        raw_name = target["name"]
        if not isinstance(raw_name, str):
            raise _invalid(f"target {index} name must be a string")
        if any(unicodedata.category(char) == "Cc" for char in raw_name):
            raise _invalid(f"target {index} name contains a control")
        name = raw_name.strip()
        if not name or len(name) > 64:
            raise _invalid(f"target {index} name is empty or too long")
        name_key = name.casefold()
        if name_key in names:
            raise _invalid("target names must be case-insensitively unique")
        names.add(name_key)

        input_name = target["input"]
        kvm_name = target["kvm"]
        if not isinstance(input_name, str) or input_name.lower() not in {"dp", "hdmi1"}:
            raise _invalid(f"target {index} input must be dp or hdmi1")
        if not isinstance(kvm_name, str) or kvm_name.lower() not in {"upstream", "typec"}:
            raise _invalid(f"target {index} kvm must be upstream or typec")
        input_name = input_name.lower()
        kvm_name = kvm_name.lower()
        if "hotkey" in target and not isinstance(target["hotkey"], str):
            raise _invalid(f"target {index} hotkey must be a string")
        is_default = target.get("default", False)
        if not isinstance(is_default, bool):
            raise _invalid(f"target {index} default must be a boolean")
        result.append((name, input_name, kvm_name, is_default))
    if sum(is_default for _, _, _, is_default in result) > 1:
        raise _invalid("multiple default targets are not allowed")
    return result


def _default_config_path() -> Path:
    override = os.environ.get("KVM_SWITCHER_CONFIG")
    if override is not None:
        if not override.strip():
            raise ValueError("KVM_SWITCHER_CONFIG must be nonempty")
        return Path(override.strip()).expanduser()
    return Path(__file__).resolve().with_name("config.json")


def _select_profile(profile: str, path: Path) -> Tuple[str, str]:
    profile_key = profile.strip().casefold()
    for name, input_name, kvm_name, _ in load_config(path):
        if name.casefold() == profile_key:
            return input_name, kvm_name
    raise ValueError("profile was not found in config")


def _select_default(path: Path) -> Tuple[str, str]:
    defaults = [
        (input_name, kvm_name)
        for _, input_name, kvm_name, is_default in load_config(path)
        if is_default
    ]
    if len(defaults) != 1:
        raise _invalid("exactly one default target is required")
    return defaults[0]


def _load_hid() -> Any:
    try:
        import hid
    except ImportError as exc:
        raise RuntimeError(
            "hidapi is required; install with "
            "python3 -m pip install -r requirements.txt"
        ) from exc
    return hid


def _transport_for_path(path: Any) -> str:
    try:
        path_text = os.fsdecode(os.fspath(path))
    except (TypeError, ValueError):
        return "libusb"
    return "hidraw" if path_text.startswith("/dev/hidraw") else "libusb"


def _open_failure(target: str, transport: str) -> RuntimeError:
    return RuntimeError(
        f"{target}: open failed (transport={transport}; "
        "check USB/hidraw udev permissions)"
    )


def _select_candidate(hid_module: Any, target: str) -> Tuple[Any, Any, str]:
    try:
        candidates = [
            item
            for item in hid_module.enumerate(VID, PID)
            if item.get("interface_number") == INTERFACE_NUMBER
        ]
    except Exception:
        raise RuntimeError(f"{target}: enumerate failed") from None
    if len(candidates) != 1:
        raise RuntimeError(f"{target}: expected exactly one HID interface")
    candidate = candidates[0]
    path = candidate.get("path") if isinstance(candidate, dict) else None
    return candidate, path, _transport_for_path(path)


def _send_once(
    target: str,
    frame: bytes,
    hid_module: Any,
    kvm_disconnect_expected: bool,
) -> SendResult:
    _, path, transport = _select_candidate(hid_module, target)

    try:
        device = hid_module.device()
    except Exception:
        raise _open_failure(target, transport) from None

    result: Optional[SendResult] = None
    write_succeeded = False
    try:
        try:
            device.open_path(path)
        except Exception:
            raise _open_failure(target, transport) from None

        try:
            write_count = device.write(frame)
        except Exception as exc:
            raise RuntimeError(f"{target}: write failed") from exc
        if write_count != REPORT_LENGTH:
            raise RuntimeError(f"{target}: write count was not 64")
        write_succeeded = True

        try:
            data = device.read(REPORT_LENGTH, READ_TIMEOUT_MS)
        except Exception as exc:
            if not kvm_disconnect_expected:
                raise RuntimeError(f"{target}: read failed") from exc
            result = SendResult(target, REPORT_LENGTH, 0, None, True)
        else:
            read_length = len(data) if data else 0
            if not kvm_disconnect_expected and read_length != REPORT_LENGTH:
                raise RuntimeError(f"{target}: read was not exactly 64 bytes")
            if kvm_disconnect_expected and read_length == 0:
                result = SendResult(target, REPORT_LENGTH, read_length, None, True)
            else:
                if read_length != REPORT_LENGTH:
                    raise RuntimeError(f"{target}: read was not exactly 64 bytes")
                result = SendResult(
                    target,
                    REPORT_LENGTH,
                    read_length,
                    sha256(bytes(data)).hexdigest(),
                    False,
                )
    finally:
        try:
            device.close()
        except Exception as exc:
            if kvm_disconnect_expected and write_succeeded and result is not None:
                result = replace(result, disconnected=True)
            elif result is not None:
                raise RuntimeError(f"{target}: close failed") from exc

    if result is None:
        raise RuntimeError(f"{target}: no result")
    return result


def probe_once(hid_module: Any) -> str:
    target = "probe"
    _, path, transport = _select_candidate(hid_module, target)
    try:
        device = hid_module.device()
    except Exception:
        raise _open_failure(target, transport) from None

    opened = False
    try:
        try:
            device.open_path(path)
        except Exception:
            raise _open_failure(target, transport) from None
        opened = True
    finally:
        try:
            device.close()
        except Exception:
            if opened:
                raise RuntimeError("probe: close failed") from None

    return f"probe transport={transport} candidates=1 no-report-io=true"


def _display(input_name: str) -> Tuple[str, bytes]:
    if input_name == "dp":
        return "Display DP", DISPLAY_DP_FRAME
    if input_name == "hdmi1":
        return "Display HDMI1", DISPLAY_HDMI1_FRAME
    raise ValueError("input must be dp or hdmi1")


def _kvm(kvm_name: str) -> Tuple[str, bytes]:
    if kvm_name == "upstream":
        return "KVM Upstream", KVM_UPSTREAM_FRAME
    if kvm_name == "typec":
        return "KVM Type-C", KVM_TYPEC_FRAME
    raise ValueError("kvm must be upstream or typec")


def run_once(input_name: str, kvm_name: str, hid_module: Any) -> Tuple[SendResult, SendResult]:
    display_target, display_frame = _display(input_name)
    kvm_target, kvm_frame = _kvm(kvm_name)
    display = _send_once(display_target, display_frame, hid_module, False)
    kvm = _send_once(kvm_target, kvm_frame, hid_module, True)
    return display, kvm


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kvm-switch")
    modes = parser.add_mutually_exclusive_group(required=False)
    modes.add_argument("--probe-hardware", action="store_true")
    modes.add_argument("--profile", metavar="NAME")
    modes.add_argument("--input", choices=("dp", "hdmi1"))
    modes.add_argument("--validate-config", metavar="PATH")
    parser.add_argument("--kvm", choices=("upstream", "typec"))
    parser.add_argument("--config", metavar="PATH")
    return parser


def _format_result(result: SendResult) -> str:
    fields = [
        result.target,
        f"write={result.write_count}",
        f"read={result.read_length}",
    ]
    if result.read_sha256 is not None:
        fields.append(f"sha256={result.read_sha256}")
    fields.append(f"disconnected={'true' if result.disconnected else 'false'}")
    if result.disconnected:
        fields.append("reply unavailable / possible expected disconnect")
    return " ".join(fields)


def main(argv: Optional[Sequence[str]] = None, hid_module: Any = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.validate_config is not None:
        if (
            args.probe_hardware
            or args.profile is not None
            or args.input is not None
            or args.kvm is not None
            or args.config is not None
        ):
            parser.error("--validate-config does not accept operational arguments")
        try:
            load_config(Path(args.validate_config))
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
        return 0
    if args.probe_hardware:
        if args.kvm is not None or args.config is not None:
            parser.error("--probe-hardware does not accept --kvm or --config")
        input_name, kvm_name = "", ""
    elif args.profile is not None:
        if args.kvm is not None:
            parser.error("--kvm requires direct --input mode")
        try:
            config_path = (
                Path(args.config) if args.config is not None else _default_config_path()
            )
            input_name, kvm_name = _select_profile(args.profile, config_path)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    elif args.input is not None:
        if args.kvm is None:
            parser.error("direct mode requires both --input and --kvm")
        if args.config is not None:
            parser.error("--config requires --profile mode")
        input_name, kvm_name = args.input, args.kvm
    else:
        if args.kvm is not None:
            parser.error("--kvm requires --input mode")
        try:
            config_path = (
                Path(args.config) if args.config is not None else _default_config_path()
            )
            input_name, kvm_name = _select_default(config_path)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2

    if hid_module is None:
        try:
            hid_module = _load_hid()
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    if args.probe_hardware:
        try:
            print(probe_once(hid_module))
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        return 0

    try:
        results = run_once(input_name, kvm_name, hid_module)
    except (RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    for result in results:
        print(_format_result(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
