import contextlib
import hashlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from typing import Optional
from unittest.mock import patch

import kvmSwitcher


EXPECTED_UDEV_RULES = [
    'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1462", ATTRS{idProduct}=="3fa4", GROUP="kvmswitch", MODE="0660", TAG+="uaccess"',
    'SUBSYSTEM=="usb", ATTR{idVendor}=="1462", ATTR{idProduct}=="3fa4", GROUP="kvmswitch", MODE="0660", TAG+="uaccess"',
]


class FakeDevice:
    def __init__(self, read_result=None, write_result=64):
        self.read_result = bytes(range(64)) if read_result is None else read_result
        self.write_result = write_result
        self.open_calls = []
        self.write_calls = []
        self.read_calls = []
        self.close_calls = 0
        self.open_error: Optional[Exception] = None
        self.write_error: Optional[Exception] = None
        self.read_error: Optional[Exception] = None
        self.close_error: Optional[Exception] = None

    def open_path(self, path):
        self.open_calls.append(path)
        if self.open_error:
            raise self.open_error

    def write(self, frame):
        self.write_calls.append(frame)
        if self.write_error:
            raise self.write_error
        return self.write_result

    def read(self, length, timeout):
        self.read_calls.append((length, timeout))
        if self.read_error:
            raise self.read_error
        return self.read_result

    def close(self):
        self.close_calls += 1
        if self.close_error:
            raise self.close_error


class FakeHid:
    def __init__(self, devices, candidates=None):
        self.devices = list(devices)
        self.candidates = (
            [{"interface_number": 0, "path": b"opaque-path"}]
            if candidates is None
            else candidates
        )
        self.enumerate_calls = []
        self.device_calls = 0

    def enumerate(self, vid, pid):
        self.enumerate_calls.append((vid, pid))
        return self.candidates

    def device(self):
        self.device_calls += 1
        return self.devices.pop(0)


def write_config(value):
    directory = tempfile.TemporaryDirectory()
    path = Path(directory.name) / "config.json"
    path.write_text(json.dumps(value), encoding="utf-8")
    return directory, path


class KvmSwitcherTests(unittest.TestCase):
    def test_default_config_path_is_adjacent_to_loaded_module(self):
        module_path = Path(kvmSwitcher.__file__).resolve()
        self.assertEqual(
            kvmSwitcher._default_config_path(), module_path.with_name("config.json")
        )

    def test_source_style_module_resolves_colocated_config(self):
        bundle_module = Path(__file__).resolve().parents[1] / "kvmSwitcher.py"
        with patch.object(kvmSwitcher, "__file__", str(bundle_module)):
            self.assertEqual(
                kvmSwitcher._default_config_path(), bundle_module.with_name("config.json")
            )

    def test_environment_config_override_is_used(self):
        with patch.dict(os.environ, {"KVM_SWITCHER_CONFIG": "/etc/kvm-switcher/config.json"}):
            self.assertEqual(
                kvmSwitcher._default_config_path(),
                Path("/etc/kvm-switcher/config.json"),
            )

    def test_empty_environment_config_override_is_rejected(self):
        with patch.dict(os.environ, {"KVM_SWITCHER_CONFIG": "  "}):
            with self.assertRaisesRegex(ValueError, "KVM_SWITCHER_CONFIG"):
                kvmSwitcher._default_config_path()

    def test_validate_config_is_semantic_and_never_loads_hid(self):
        directory, config_path = write_config(
            {
                "targets": [
                    {"name": "Raspberry", "input": "hdmi1", "kvm": "typec"}
                ]
            }
        )
        self.addCleanup(directory.cleanup)
        output = io.StringIO()
        errors = io.StringIO()
        with patch.object(
            kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
        ) as loader, contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(["--validate-config", str(config_path)], None)

        self.assertEqual(code, 0)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "")
        loader.assert_not_called()

    def test_validate_config_rejects_malformed_input_before_hid(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        config_path = Path(directory.name) / "config.json"
        config_path.write_text('{"targets":', encoding="utf-8")
        errors = io.StringIO()
        with patch.object(
            kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
        ), contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(["--validate-config", str(config_path)], None)

        self.assertEqual(code, 2)
        self.assertIn("invalid config", errors.getvalue())

    def test_validate_config_rejects_operational_arguments(self):
        directory, config_path = write_config(
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream"}]}
        )
        self.addCleanup(directory.cleanup)
        for extra in (
            ["--probe-hardware"],
            ["--profile", "A"],
            ["--input", "dp"],
            ["--kvm", "upstream"],
            ["--config", str(config_path)],
        ):
            with self.subTest(extra=extra):
                with patch.object(
                    kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
                ):
                    with self.assertRaises(SystemExit) as raised:
                        kvmSwitcher.main(
                            ["--validate-config", str(config_path), *extra], None
                        )
                self.assertEqual(raised.exception.code, 2)

    def test_fixed_frames_are_exactly_64_bytes(self):
        expected = (
            (kvmSwitcher.DISPLAY_DP_FRAME, b"5b00500002\r"),
            (kvmSwitcher.DISPLAY_HDMI1_FRAME, b"5b00500000\r"),
            (kvmSwitcher.KVM_UPSTREAM_FRAME, b"5b008>0001\r"),
            (kvmSwitcher.KVM_TYPEC_FRAME, b"5b008>0002\r"),
        )
        for frame, payload in expected:
            self.assertEqual(frame, b"\x01" + payload + b"\0" * 52)
            self.assertEqual(len(frame), 64)

    def test_udev_rules_are_exact_and_narrow(self):
        repository_root = Path(__file__).resolve().parents[2]
        rule_paths = (
            repository_root / "linux" / "udev" / "99-kvm-switcher.rules",
            repository_root
            / "packaging"
            / "debian"
            / "usr"
            / "lib"
            / "udev"
            / "rules.d"
            / "60-kvm-switcher.rules",
        )
        for rule_path in rule_paths:
            with self.subTest(rule_path=rule_path):
                lines = rule_path.read_text(encoding="utf-8").splitlines()
                self.assertEqual(lines, EXPECTED_UDEV_RULES)
                self.assertFalse(
                    any(
                        'SUBSYSTEM=="usb"' in line and 'ATTRS{idVendor}' in line
                        for line in lines
                    )
                )

    def test_probe_success_is_no_write_and_classifies_transport(self):
        for path, transport in (
            ("1-1.3:1.0", "libusb"),
            (b"/dev/hidraw7", "hidraw"),
        ):
            with self.subTest(transport=transport):
                device = FakeDevice()
                fake_hid = FakeHid(
                    [device], [{"interface_number": 0, "path": path}]
                )
                output = io.StringIO()
                with patch.object(
                    kvmSwitcher,
                    "load_config",
                    side_effect=AssertionError("probe loaded config"),
                ), patch.object(
                    kvmSwitcher,
                    "_default_config_path",
                    side_effect=AssertionError("probe resolved config"),
                ), contextlib.redirect_stdout(output):
                    code = kvmSwitcher.main(["--probe-hardware"], fake_hid)

                self.assertEqual(code, 0)
                self.assertEqual(
                    output.getvalue().strip(),
                    f"probe transport={transport} candidates=1 no-report-io=true",
                )
                self.assertEqual(fake_hid.enumerate_calls, [(0x1462, 0x3FA4)])
                self.assertEqual(fake_hid.device_calls, 1)
                self.assertEqual(device.open_calls, [path])
                self.assertEqual(device.write_calls, [])
                self.assertEqual(device.read_calls, [])
                self.assertEqual(device.close_calls, 1)

    def test_probe_rejects_invalid_argument_combinations(self):
        for argv in (
            ["--probe-hardware", "--kvm", "upstream"],
            ["--probe-hardware", "--config", "config.json"],
            ["--probe-hardware", "--profile", "Raspberry"],
        ):
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit) as raised:
                    kvmSwitcher.main(argv, FakeHid([]))
                self.assertEqual(raised.exception.code, 2)

    def test_probe_open_failure_is_sanitized_and_closes_best_effort(self):
        device = FakeDevice()
        device.open_error = OSError("secret path and serial")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(
                ["--probe-hardware"],
                FakeHid([device], [{"interface_number": 0, "path": "1-1.3:1.0"}]),
            )

        text = errors.getvalue()
        self.assertEqual(code, 1)
        self.assertIn("transport=libusb", text)
        self.assertIn("check USB/hidraw udev permissions", text)
        self.assertNotIn("1-1.3:1.0", text)
        self.assertNotIn("secret path", text)
        self.assertNotIn("serial", text)
        self.assertNotIn("Traceback", text)
        self.assertEqual(device.close_calls, 1)
        self.assertEqual(device.write_calls, [])
        self.assertEqual(device.read_calls, [])

    def test_normal_open_failure_identifies_transport_without_retry(self):
        device = FakeDevice()
        device.open_error = OSError("secret raw path and serial")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(
                ["--input", "dp", "--kvm", "upstream"],
                FakeHid([device], [{"interface_number": 0, "path": b"/dev/hidraw9"}]),
            )

        text = errors.getvalue()
        self.assertEqual(code, 1)
        self.assertIn("Display DP", text)
        self.assertIn("transport=hidraw", text)
        self.assertIn("check USB/hidraw udev permissions", text)
        self.assertNotIn("/dev/hidraw9", text)
        self.assertNotIn("secret raw path", text)
        self.assertNotIn("serial", text)
        self.assertNotIn("Traceback", text)
        self.assertEqual(device.close_calls, 1)
        self.assertEqual(device.write_calls, [])
        self.assertEqual(device.read_calls, [])

    def test_probe_close_failure_is_failure(self):
        device = FakeDevice()
        device.close_error = OSError("secret close path")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(["--probe-hardware"], FakeHid([device]))

        text = errors.getvalue()
        self.assertEqual(code, 1)
        self.assertIn("probe: close failed", text)
        self.assertNotIn("secret close path", text)
        self.assertNotIn("Traceback", text)
        self.assertEqual(device.close_calls, 1)
        self.assertEqual(device.write_calls, [])
        self.assertEqual(device.read_calls, [])

    def test_direct_args_select_fixed_order_and_one_shot_io(self):
        display = FakeDevice()
        kvm = FakeDevice()
        fake_hid = FakeHid([display, kvm])

        result = kvmSwitcher.run_once("hdmi1", "typec", fake_hid)

        self.assertEqual(fake_hid.enumerate_calls, [(0x1462, 0x3FA4)] * 2)
        self.assertEqual(fake_hid.device_calls, 2)
        self.assertEqual(display.open_calls, [b"opaque-path"])
        self.assertEqual(display.write_calls, [kvmSwitcher.DISPLAY_HDMI1_FRAME])
        self.assertEqual(display.read_calls, [(64, 1500)])
        self.assertEqual(display.close_calls, 1)
        self.assertEqual(kvm.write_calls, [kvmSwitcher.KVM_TYPEC_FRAME])
        self.assertEqual(kvm.read_calls, [(64, 1500)])
        self.assertEqual(kvm.close_calls, 1)
        self.assertEqual(
            [item.target for item in result], ["Display HDMI1", "KVM Type-C"]
        )

    def test_profile_config_ignores_hotkey(self):
        directory, config_path = write_config(
            {
                "targets": [
                    {
                        "name": "Raspberry",
                        "input": "hdmi1",
                        "kvm": "typec",
                        "hotkey": "Ctrl+Shift+Alt+P",
                    }
                ]
            }
        )
        self.addCleanup(directory.cleanup)
        display = FakeDevice()
        kvm = FakeDevice()

        code = kvmSwitcher.main(
            ["--profile", "Raspberry", "--config", str(config_path)],
            FakeHid([display, kvm]),
        )

        self.assertEqual(code, 0)
        self.assertEqual(display.write_calls, [kvmSwitcher.DISPLAY_HDMI1_FRAME])
        self.assertEqual(kvm.write_calls, [kvmSwitcher.KVM_TYPEC_FRAME])

    def test_bare_and_config_only_commands_select_the_sole_default(self):
        directory, config_path = write_config(
            {
                "targets": [
                    {"name": "Raspberry", "input": "hdmi1", "kvm": "typec", "default": False},
                    {"name": "Windows", "input": "dp", "kvm": "upstream", "default": True},
                ]
            }
        )
        self.addCleanup(directory.cleanup)

        for argv in (("--config", str(config_path)), tuple()):
            with self.subTest(argv=argv):
                display = FakeDevice()
                kvm = FakeDevice()
                fake_hid = FakeHid([display, kvm])
                if not argv:
                    default_path = patch.object(
                        kvmSwitcher, "_default_config_path", return_value=config_path
                    )
                else:
                    default_path = contextlib.nullcontext()
                with default_path:
                    code = kvmSwitcher.main(list(argv), fake_hid)

                self.assertEqual(code, 0)
                self.assertEqual(
                    [display.write_calls[0], kvm.write_calls[0]],
                    [kvmSwitcher.DISPLAY_DP_FRAME, kvmSwitcher.KVM_UPSTREAM_FRAME],
                )
                self.assertEqual(fake_hid.enumerate_calls, [(0x1462, 0x3FA4)] * 2)

    def test_profile_zero_default_is_valid_but_multiple_default_and_zero_default_bare_fail_before_hid(self):
        zero_directory, zero_path = write_config(
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream"}]}
        )
        self.addCleanup(zero_directory.cleanup)
        display = FakeDevice()
        kvm = FakeDevice()
        profile_code = kvmSwitcher.main(
            ["--profile", "A", "--config", str(zero_path)], FakeHid([display, kvm])
        )
        self.assertEqual(profile_code, 0)
        self.assertEqual(display.write_calls, [kvmSwitcher.DISPLAY_DP_FRAME])
        self.assertEqual(kvm.write_calls, [kvmSwitcher.KVM_UPSTREAM_FRAME])

        for value in (
            {
                "targets": [
                    {"name": "A", "input": "dp", "kvm": "upstream", "default": True},
                    {"name": "B", "input": "hdmi1", "kvm": "typec", "default": True},
                ]
            },
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream"}]},
        ):
            directory, path = write_config(value)
            self.addCleanup(directory.cleanup)
            fake_hid = FakeHid([])
            errors = io.StringIO()
            with patch.object(
                kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
            ), contextlib.redirect_stderr(errors):
                code = kvmSwitcher.main(["--config", str(path)], None)
            self.assertEqual(code, 2)
            self.assertIn("default", errors.getvalue())
            self.assertEqual(fake_hid.enumerate_calls, [])

        multiple_directory, multiple_path = write_config(
            {
                "targets": [
                    {"name": "A", "input": "dp", "kvm": "upstream", "default": True},
                    {"name": "B", "input": "hdmi1", "kvm": "typec", "default": True},
                ]
            }
        )
        self.addCleanup(multiple_directory.cleanup)
        with patch.object(
            kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
        ):
            profile_code = kvmSwitcher.main(
                ["--profile", "A", "--config", str(multiple_path)], None
            )
        self.assertEqual(profile_code, 2)

    def test_kvm_alone_is_argument_error_and_never_selects_default(self):
        fake_hid = FakeHid([])
        with self.assertRaises(SystemExit) as raised:
            kvmSwitcher.main(["--kvm", "upstream"], fake_hid)
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(fake_hid.enumerate_calls, [])

        with self.assertRaises(SystemExit) as raised:
            kvmSwitcher.main(
                ["--input", "dp", "--kvm", "upstream", "--config", "config.json"],
                fake_hid,
            )
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(fake_hid.enumerate_calls, [])

    def test_invalid_default_config_types_and_duplicates_fail_before_hid(self):
        values = (
            '{"targets":[{"name":"A","input":"dp","kvm":"upstream","default":null}]}',
            '{"targets":[{"name":"A","input":"dp","kvm":"upstream","default":1}]}',
            '{"targets":[{"name":"A","input":"dp","kvm":"upstream","default":false,"default":true}]}',
        )
        for value in values:
            with self.subTest(value=value):
                directory = tempfile.TemporaryDirectory()
                self.addCleanup(directory.cleanup)
                path = Path(directory.name) / "config.json"
                path.write_text(value, encoding="utf-8")
                with patch.object(
                    kvmSwitcher, "_load_hid", side_effect=AssertionError("loaded HID")
                ):
                    code = kvmSwitcher.main(["--config", str(path)], None)
                self.assertEqual(code, 2)

    def test_config_validation_rejects_unknown_duplicate_and_bad_values(self):
        invalid_values = (
            {
                "targets": [
                    {
                        "name": "A",
                        "input": "dp",
                        "kvm": "upstream",
                        "extra": 1,
                    }
                ]
            },
            {
                "targets": [
                    {"name": "A", "input": "dp", "kvm": "upstream"},
                    {"name": "a", "input": "hdmi1", "kvm": "typec"},
                ]
            },
            {"targets": [{"name": "A", "input": "vga", "kvm": "upstream"}]},
            {
                "targets": [
                    {"name": "A", "input": "dp", "kvm": "upstream", "hotkey": 1}
                ]
            },
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream", "default": None}]},
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream", "default": "yes"}]},
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream", "default": 1}]},
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream", "default": {}}]},
            {"targets": [{"name": "A", "input": "dp", "kvm": "upstream", "default": []}]},
            {
                "targets": [
                    {"name": "A", "input": "dp", "kvm": "upstream", "default": True},
                    {"name": "B", "input": "hdmi1", "kvm": "typec", "default": True},
                ]
            },
            {"other": []},
        )
        for value in invalid_values:
            directory, path = write_config(value)
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    kvmSwitcher.load_config(path)
            directory.cleanup()

        duplicate_values = (
            '{"targets":[{"name":"A","name":"B","input":"dp","kvm":"upstream"}]}',
            '{"targets":[{"name":"A","input":"dp","kvm":"upstream","default":false,"default":true}]}',
        )
        for value in duplicate_values:
            directory = tempfile.TemporaryDirectory()
            with self.subTest(duplicate=value):
                path = Path(directory.name) / "config.json"
                path.write_text(value, encoding="utf-8")
                with self.assertRaises(ValueError):
                    kvmSwitcher.load_config(path)
            directory.cleanup()

    def test_zero_or_multiple_candidates_reject_before_open(self):
        for candidates in (
            [],
            [
                {"interface_number": 0, "path": b"one"},
                {"interface_number": 0, "path": b"two"},
            ],
        ):
            with self.subTest(count=len(candidates)):
                device = FakeDevice()
                fake_hid = FakeHid([device], candidates)
                with self.assertRaisesRegex(RuntimeError, "exactly one"):
                    kvmSwitcher.run_once("dp", "upstream", fake_hid)
                self.assertEqual(fake_hid.device_calls, 0)
                self.assertEqual(device.open_calls, [])

                probe_device = FakeDevice()
                probe_hid = FakeHid([probe_device], candidates)
                with self.assertRaisesRegex(RuntimeError, "exactly one"):
                    kvmSwitcher.probe_once(probe_hid)
                self.assertEqual(probe_hid.device_calls, 0)
                self.assertEqual(probe_device.open_calls, [])

    def test_display_failure_stops_kvm(self):
        display = FakeDevice()
        display.write_error = OSError("display failure")
        kvm = FakeDevice()
        fake_hid = FakeHid([display, kvm])

        with self.assertRaisesRegex(RuntimeError, "Display DP: write failed"):
            kvmSwitcher.run_once("dp", "upstream", fake_hid)

        self.assertEqual(fake_hid.device_calls, 1)
        self.assertEqual(display.close_calls, 1)
        self.assertEqual(kvm.open_calls, [])

    def test_partial_display_reply_fails(self):
        display = FakeDevice(read_result=b"partial")
        kvm = FakeDevice()
        fake_hid = FakeHid([display, kvm])

        with self.assertRaisesRegex(RuntimeError, "Display DP: read"):
            kvmSwitcher.run_once("dp", "upstream", fake_hid)

        self.assertEqual(display.read_calls, [(64, 1500)])
        self.assertEqual(display.close_calls, 1)
        self.assertEqual(fake_hid.device_calls, 1)

    def test_kvm_disconnect_is_neutral(self):
        display = FakeDevice()
        kvm = FakeDevice(read_result=b"")
        kvm.read_error = OSError("gone")
        results = kvmSwitcher.run_once("dp", "upstream", FakeHid([display, kvm]))
        self.assertTrue(results[1].disconnected)
        self.assertEqual(results[1].write_count, 64)
        self.assertEqual(results[1].read_length, 0)
        self.assertIsNone(results[1].read_sha256)

    def test_short_kvm_reply_fails_without_retry(self):
        for kvm_name, target in (("upstream", "KVM Upstream"), ("typec", "KVM Type-C")):
            with self.subTest(kvm_name=kvm_name):
                display = FakeDevice()
                kvm = FakeDevice(read_result=b"partial")
                fake_hid = FakeHid([display, kvm])

                with self.assertRaisesRegex(
                    RuntimeError, f"{target}: read was not exactly 64 bytes"
                ):
                    kvmSwitcher.run_once("dp", kvm_name, fake_hid)

                self.assertEqual(len(kvm.write_calls), 1)
                self.assertEqual(len(kvm.read_calls), 1)
                self.assertEqual(kvm.close_calls, 1)

    def test_kvm_close_disconnect_is_neutral(self):
        display = FakeDevice()
        kvm = FakeDevice(read_result=bytes(range(64)))
        kvm.close_error = OSError("gone on close")

        results = kvmSwitcher.run_once("dp", "upstream", FakeHid([display, kvm]))

        self.assertTrue(results[1].disconnected)
        self.assertEqual(results[1].read_length, 64)
        self.assertEqual(kvm.close_calls, 1)

    def test_write_and_read_errors_have_no_retry(self):
        display = FakeDevice()
        display.write_error = OSError("write")
        with self.assertRaises(RuntimeError):
            kvmSwitcher.run_once("dp", "upstream", FakeHid([display, FakeDevice()]))
        self.assertEqual(len(display.write_calls), 1)
        self.assertEqual(display.read_calls, [])

        display = FakeDevice()
        kvm = FakeDevice()
        kvm.read_error = OSError("disconnect")
        kvm_result = kvmSwitcher.run_once("dp", "upstream", FakeHid([display, kvm]))
        self.assertTrue(kvm_result[1].disconnected)
        self.assertEqual(len(kvm.read_calls), 1)

    def test_cli_privacy_and_exit_codes(self):
        reply = bytes(range(64))
        display = FakeDevice(read_result=reply)
        kvm = FakeDevice()
        kvm.read_error = OSError("disconnect")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = kvmSwitcher.main(
                ["--input", "dp", "--kvm", "upstream"], FakeHid([display, kvm])
            )
        text = output.getvalue()
        self.assertEqual(code, 0)
        self.assertIn(hashlib.sha256(reply).hexdigest(), text)
        self.assertIn("disconnected=true", text)
        self.assertIn("reply unavailable / possible expected disconnect", text)
        self.assertNotIn(repr(reply), text)
        self.assertNotIn("opaque-path", text)
        self.assertNotIn("serial", text.lower())

        failed = FakeDevice()
        failed.write_error = OSError("failure")
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            code = kvmSwitcher.main(
                ["--input", "dp", "--kvm", "upstream"], FakeHid([failed])
            )
        self.assertEqual(code, 1)
        self.assertIn("error:", errors.getvalue())

    def test_help_does_not_load_hid_and_missing_dependency_is_concise(self):
        with patch.object(kvmSwitcher, "_load_hid") as loader:
            with self.assertRaises(SystemExit):
                kvmSwitcher.main(["--help"])
            loader.assert_not_called()

        errors = io.StringIO()
        with patch.object(
            kvmSwitcher,
            "_load_hid",
            side_effect=RuntimeError("hidapi is required; install with pip"),
        ):
            with contextlib.redirect_stderr(errors):
                code = kvmSwitcher.main(["--input", "dp", "--kvm", "upstream"])
        self.assertEqual(code, 1)
        self.assertIn("hidapi is required", errors.getvalue())
        self.assertNotIn("Traceback", errors.getvalue())

    def test_installer_uses_local_package_and_exact_command_link(self):
        installer = Path(__file__).resolve().parents[1] / "install.sh"
        source = installer.read_text(encoding="utf-8")
        self.assertNotIn("pip install --upgrade", source)
        self.assertIn('pip install -r "$BUNDLE_DIR/requirements.txt"', source)
        self.assertIn('pip install --no-deps -e "$BUNDLE_DIR"', source)
        self.assertIn('"$VENV_DIR/bin/kvm-switch" --help', source)
        self.assertIn(
            'ln -sf "$VENV_DIR/bin/kvm-switch" "$LAUNCHER"',
            source,
        )
        self.assertNotIn('cat > "$LAUNCHER"', source)
        self.assertNotRegex(source, r"(?m)^\s*(sudo|apt|brew|pkg)(?:\s|$)")


if __name__ == "__main__":
    unittest.main()
