#!/usr/bin/env python3
"""Check nested calls, parallel work, startup dependencies, and one-file reports."""

import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("mdf_profile", root / "scripts/profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


def span(name, track, start_ms, duration_ms, depth=0, kind="work"):
    return {"name": name, "track": track, "kind": kind, "source": "src/main.zig",
            "function": "test", "line": 12, "start_ns": round(start_ms * 1_000_000),
            "duration_ns": round(duration_ms * 1_000_000), "depth": depth}


def fixture():
    return {"profile_version": 1, "metrics": {"first_frame_ms": 20}, "dropped_events": 0,
            "events": [span("GUI", "gui", 0, 10), span("child", "gui", 2, 4, 1),
                       span("grandchild", "gui", 3, 1, 2), span("worker", "document", 3, 5),
                       span("worker child", "document", 4, 3, 1),
                       span("event wait", "gui", 10, 10, kind="wait")]}


def size_fixture(path, symbols=True, identity=b"matching build", diagram=None, modules=None):
    """ELF with aliased functions, an embedded font, and RAM-only BSS."""
    strings = b"\0main\0main_alias\0jpeg_fixture\0mdf_font_object\0"
    names = {name: strings.index(name.encode() + b"\0") for name in
             ("main", "main_alias", "jpeg_fixture", "mdf_font_object")}
    address = 0x400000
    entries = [(0, 0, 0, 0, 0, 0),
               (names["main"], 0x12, 0, 1, address + 128, 32),
               (names["main_alias"], 0x12, 0, 1, address + 128, 32),
               (names["jpeg_fixture"], 0x12, 0, 1, address + 160, 32),
               (names["mdf_font_object"], 0x11, 0, 2, address + 256, 96)]
    table = b"".join(struct.pack("<IBBHQQ", *entry) for entry in entries)
    font = b"font-fixture-with-known-file-size"
    specs = [("", 0, 0, 0, 0, 0, 0, 0),
             (".text", 1, 6, address + 128, 128, 96, 0, 0),
             (".rodata", 1, 2, address + 256, 256, 96, 0, 0),
             (".bss", 8, 3, address + 4096, 352, 1024 * 1024, 0, 0),
             (".note.gnu.build-id", 7, 2, address + 64, 64, len(identity), 0, 0)]
    if symbols:
        specs += [(".strtab", 3, 0, 0, 384, len(strings), 0, 0),
                  (".symtab", 2, 0, 0, 448, len(table), 5, 24)]
    if diagram is not None:
        specs.append((".mdf_diagram", 1, 0, 0, 768, len(diagram), 0, 0))
    for index, (name, payload) in enumerate((modules or {}).items()):
        specs.append((name, 1, 0, 0, 768 + index * 96, len(payload), 0, 0))
    specs.append((".shstrtab", 3, 0, 0, 640, 0, 0, 0))
    section_names = b"\0" + b"".join(s[0].encode() + b"\0" for s in specs if s[0])
    data = bytearray(1024 + len(specs) * 64)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<16sHHIQQQIHHHHHH", data, 0, ident, 2, 62, 1, address + 128,
                     0, 1024, 0, 64, 0, 0, 64, len(specs), len(specs) - 1)
    data[64:64 + len(identity)] = identity
    data[288:288 + len(font)] = font
    if symbols:
        data[384:384 + len(strings)] = strings
        data[448:448 + len(table)] = table
    data[640:640 + len(section_names)] = section_names
    if diagram is not None: data[768:768+len(diagram)] = diagram
    for index, payload in enumerate((modules or {}).values()):
        data[768+index*96:768+index*96+len(payload)] = payload
    for index, (name, kind, flags, addr, offset, size, link, stride) in enumerate(specs):
        if name == ".shstrtab":
            size = len(section_names)
        name_offset = section_names.index(name.encode() + b"\0") if name else 0
        struct.pack_into("<IIQQQQIIQQ", data, 1024 + index * 64,
                         name_offset, kind, flags, addr, offset, size, link, 0, 1, stride)
    path.write_bytes(data)
    return font


class ProfileTests(unittest.TestCase):
    def test_runtime_conditions_preserve_power_mode_affinity_and_system_load(self):
        with mock.patch.object(profile.os, "sched_getaffinity", return_value={3, 1}), \
             mock.patch.object(profile.os, "getloadavg", return_value=(17.5, 14.0, 8.0)), \
             mock.patch.object(Path, "read_text", return_value="powersave\n"):
            self.assertEqual(profile.runtime_conditions(), {
                "cpu_affinity": [1, 3], "cpu_governors": ["powersave"],
                "load_average": [17.5, 14.0, 8.0]})

    def test_cache_probe_observes_owned_file_pages_without_reading_the_file(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "mdf"
            binary.write_bytes(b"page-cache-fixture" * 500)
            state = profile.binary_cache_state(binary)
            self.assertGreater(state["resident_pages"], 0)
            self.assertLessEqual(state["resident_pages"], state["total_pages"])
            self.assertEqual(state["total_pages"], (binary.stat().st_size + state["page_size"] - 1) // state["page_size"])
            self.assertIn("PROT_NONE", state["method"])

    def test_warm_executable_aborts_before_process_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "profile.html"
            with mock.patch.object(profile, "require_wayland_session"), \
                    mock.patch.object(profile, "drop_linux_caches", return_value={"success": True}), \
                    mock.patch.object(profile, "binary_cache_state", return_value={"resident_pages": 3, "total_pages": 8}), \
                    mock.patch.object(profile.subprocess, "run") as launch:
                with self.assertRaisesRegex(RuntimeError, "3/8 pages resident"):
                    profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 1, output)
                launch.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_external_launch_clock_includes_loader_time_without_shifting_durations(self):
        data = fixture()
        data["main_started_ns"] = 105_000_000
        data["metrics"].update({"first_document_ms": 12, "scaffold_ms": 8, "backend_ms": 2,
                                "first_document_commit_ms": 11,
                                "read_ms": 1, "parse_ms": 3, "window_ms": 6})
        result = profile.analyze_run(profile.include_process_launch(data, 100_000_000, 130_000_000))
        self.assertEqual(result["metrics"]["pre_main_ms"], 5)
        self.assertEqual(result["metrics"]["first_document_ms"], 17)
        self.assertEqual(result["metrics"]["first_document_commit_ms"], 16)
        self.assertEqual(result["metrics"]["first_frame_ms"], 25)
        self.assertEqual(result["metrics"]["in_app_viewport_ms"], 12)
        self.assertEqual(result["metrics"]["profiler_exit_ms"], 5)
        self.assertEqual([result["metrics"][key] for key in ("read_ms", "parse_ms", "window_ms")], [1, 3, 6])
        self.assertEqual(result["process_lifecycle_ms"], 30)
        main_call = next(event for event in result["events"] if event["name"] == "GUI")
        self.assertEqual((main_call["start_ns"], main_call["duration_ns"]), (5_000_000, 10_000_000))
        self.assertEqual(result["events"][0]["track"], "launch")
        self.assertTrue(result["events"][0]["boundary"])
        for totals in result["thread_summary"].values():
            self.assertEqual(sum(totals.values()), 25)
        self.assertEqual(data["events"][0]["start_ns"], 0)
        self.assertEqual(data["metrics"]["first_document_ms"], 12)

    def test_external_clock_rejects_missing_or_inconsistent_boundaries(self):
        for stamp in (None, 0, 99_000_000, 131_000_000, 129_000_000):
            data = fixture()
            data["main_started_ns"] = stamp
            with self.assertRaises(ValueError):
                profile.include_process_launch(data, 100_000_000, 130_000_000)

    def test_viewport_cannot_precede_its_buffer_commit_or_socket_flush(self):
        for commit,flush in [(11,11), (9,11), (9,8)]:
            data=fixture();data['metrics'].update(first_document_ms=10,
                first_document_commit_ms=commit,first_document_flush_ms=flush)
            with self.assertRaisesRegex(ValueError,'Viewport callback preceded'):
                profile.analyze_run(data)
        data=fixture();data['metrics'].update(first_document_ms=10,
            first_document_commit_ms=9,first_document_flush_ms=9.5)
        self.assertEqual(profile.analyze_run(data)['metrics']['first_document_flush_ms'],9.5)

    def test_compressed_payload_counts_physical_bytes_only(self):
        with tempfile.TemporaryDirectory() as directory:
            project=Path(directory);binary=project/'mdf'
            packed=b'packed-module'
            payload=struct.pack('<8sIIQQII',b'MDFDG01\0',1,40,len(packed),7_000_000,123,0)+packed
            size_fixture(binary,diagram=payload)
            result=profile.binary_breakdown(project,binary)
            self.assertEqual(sum(g['bytes'] for g in result['children']),binary.stat().st_size)
            group=next(g for g in result['children'] if g['name']=='Compressed diagram module')
            self.assertEqual(group['bytes'],len(payload))
            self.assertEqual(result['diagram_module']['expanded_bytes'],7_000_000)
            self.assertLess(result['bytes'],7_000_000)

    def test_binary_treemap_counts_file_bytes_once_and_excludes_bss(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            binary = project / "mdf"
            font = size_fixture(binary)
            fonts = project / "assets/fonts/open-sans"
            fonts.mkdir(parents=True)
            (fonts / "OpenSans-Regular.ttf").write_bytes(font)
            result = profile.binary_breakdown(project, binary)
            self.assertTrue(result["symbols_available"])
            self.assertEqual(result["bytes"], binary.stat().st_size)
            self.assertEqual(sum(item["bytes"] for item in result["children"]), result["bytes"])
            groups = {item["name"]: item for item in result["children"]}
            application = {item["name"]: item["bytes"] for item in groups["Application"]["children"]}
            self.assertEqual(application["Main entry point"], 32)  # Aliases share the same bytes.
            self.assertEqual(application["Core API"], 96 - len(font))
            self.assertEqual(groups["Fonts"]["bytes"], len(font))
            self.assertEqual(groups["Bundled libraries"]["children"], [{"name": "JPEG", "bytes": 32}])
            self.assertNotIn(".bss", json.dumps(result))
            self.assertLess(len(json.dumps(result)), 2000)

    def test_separate_renderer_payloads_have_independent_physical_sizes(self):
        with tempfile.TemporaryDirectory() as directory:
            project=Path(directory);binary=project/'mdf'
            modules={}
            for index,name in enumerate(('.mdf_mermaid','.mdf_svg')):
                packed=b'packed'+bytes([index])
                modules[name]=struct.pack('<8sIIQQII',b'MDFDG01\0',2,40,len(packed),7_000_000+index,123,0)+packed
            size_fixture(binary,modules=modules)
            result=profile.binary_breakdown(project,binary)
            self.assertEqual(sum(group['bytes'] for group in result['children']),binary.stat().st_size)
            group=next(g for g in result['children'] if g['name']=='Compressed renderers')
            self.assertEqual(group['bytes'],sum(map(len,modules.values())))
            self.assertEqual({m['name'] for m in result['diagram_modules']},{'Mermaid renderer','SVG rendering'})
            self.assertNotIn('diagram_module',result)

    def test_compressed_italic_font_counts_packed_bytes_only(self):
        with tempfile.TemporaryDirectory() as directory:
            project=Path(directory);binary=project/'mdf'
            size_fixture(binary)
            fonts=project/'assets/fonts/open-sans';fonts.mkdir(parents=True)
            raw=b'optional-italic-font'*8
            (fonts/'OpenSans-Italic.ttf').write_bytes(raw)
            packed=struct.pack('<8sII',b'MDFONT1\0',len(raw),profile.zlib.crc32(raw))+profile.zlib.compress(raw,9)
            data=bytearray(binary.read_bytes());data[288:384]=bytes(96);data[288:288+len(packed)]=packed;binary.write_bytes(data)
            result=profile.binary_breakdown(project,binary)
            group=next(g for g in result['children'] if g['name']=='Fonts')
            self.assertEqual(group['children'],[{'name':'Open Sans Italic (zlib)','bytes':len(packed)}])
            self.assertEqual(sum(g['bytes'] for g in result['children']),binary.stat().st_size)

    def test_stripped_binary_uses_only_matching_build_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            binary = project / "mdf"
            debug = project / "mdf.debug"
            size_fixture(binary, symbols=False)
            size_fixture(debug, identity=b"different build")
            result = profile.binary_breakdown(project, binary)
            self.assertFalse(result["symbols_available"])
            self.assertNotIn("Application", {item["name"] for item in result["children"]})
            size_fixture(debug)
            result = profile.binary_breakdown(project, binary)
            self.assertTrue(result["symbols_available"])
            self.assertIn("Application", {item["name"] for item in result["children"]})
            self.assertEqual(sum(item["bytes"] for item in result["children"]), binary.stat().st_size)

    def test_size_analysis_rejects_invalid_files_without_breaking_the_report(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            binary = project / "mdf"
            for data in (b"not an ELF", b"\x7fELF\x02\x01" + bytes(58)):
                binary.write_bytes(data)
                self.assertFalse(profile.binary_breakdown(project, binary)["available"])

    def test_fltk_bundled_codec_symbols_are_not_counted_as_fltk_ui(self):
        for symbol, library in (("fltk_png_read_row.constprop.0", "PNG"),
                                ("fltk_z_inflate", "ZLIB"), ("jpeg_read_header", "JPEG"),
                                ("libdecor_frame_commit", "libdecor")):
            self.assertEqual(profile.symbol_family(symbol), ("Bundled libraries", library))

    def test_native_diagram_symbols_are_attributed_separately_from_fltk(self):
        self.assertEqual(profile.symbol_family('_RNvC123_19mermaid_rs_renderer6render'),
                         ('Bundled libraries', 'Mermaid renderer'))
        self.assertEqual(profile.symbol_family('_RNvC123_4usvg6render'),
                         ('Bundled libraries', 'SVG rendering'))
        self.assertEqual(profile.symbol_family('_RNvC123_3std2io'),
                         ('Language runtimes', 'Rust standard library & diagram support'))

    def test_nested_spans_do_not_double_count_self_time(self):
        run = profile.analyze_run(fixture())
        costs = {event["name"]: event for event in run["events"]}
        self.assertEqual(costs["GUI"]["self_ns"] / 1_000_000, 6)
        self.assertEqual(costs["child"]["self_ns"] / 1_000_000, 3)
        self.assertEqual(costs["grandchild"]["self_ns"] / 1_000_000, 1)
        self.assertEqual(costs["worker"]["self_ns"] / 1_000_000, 2)
        self.assertEqual(sum(p["self_ns"] / 1_000_000 for p in run["events"] if p["kind"] == "work"), 15)

    def test_wall_total_counts_preload_nested_work_and_parallel_worker_once(self):
        data = fixture()
        data["main_started_ns"] = 1_005_000_000
        data["events"].append(span("parallel navigation", "navigation", 1, 19))
        run = profile.analyze_run(profile.include_process_launch(data, 1_000_000_000, 1_040_000_000))
        self.assertEqual(run["wall_accounting"], {"total_ns": 25_000_000,
            "before_main_ns": 5_000_000, "gui_work_ns": 10_000_000,
            "gui_wait_ns": 10_000_000, "untraced_ns": 0})
        self.assertGreater(sum(e["duration_ns"] for e in run["events"]), run["wall_accounting"]["total_ns"])
        self.assertEqual(sum(value for key, value in run["wall_accounting"].items() if key != "total_ns"),
                         run["wall_accounting"]["total_ns"])

    def test_call_graph_counts_outer_blocks_once_for_each_endpoint(self):
        data=fixture();data['metrics']['first_document_ms']=8
        data['main_started_ns']=1_005_000_000
        run=profile.analyze_run(profile.include_process_launch(data,1_000_000_000,1_040_000_000))
        model=run['call_graph'];nodes={n['id']:n for n in model['nodes']}
        for name,total in [('viewport',13_000_000),('ready',25_000_000)]:
            path=model['paths'][name]
            self.assertEqual(path['total_ns'],total)
            self.assertEqual(sum(nodes[key]['duration_ns'] for key in path['node_ids']),total)
            self.assertFalse(any(nodes[key]['track']=='document' for key in path['node_ids']))
        # Child totals are inclusive and nested, never extra outer-node cost.
        self.assertTrue(any(row['duration_ns']==1_000_000 for n in model['nodes'] for row in n['rows']))
        self.assertTrue(all(n['duration_ns']>=0 and n['start_ns']>=0 for n in model['nodes']))

    def test_call_graph_worker_path_requires_a_real_blocking_handoff(self):
        for wake in ('other descriptor','compositor','timeout',None):
            data={'profile_version':1,'metrics':{'first_document_ms':2,'first_frame_ms':10},'events':[
                span('Initialize window','gui',0,2),span('Draw window','gui',2,1),
                span('Wait for system monospace','gui',3,6.1,kind='wait'),
                span('Accept document and prepared workers','gui',9.1,.8),
                span('Adopt system monospace and reflow code','gui',9.2,.5,1),
                span('Prepare deferred system monospace','fonts',2.1,6.9),
                span('Read configuration','fonts',3,2,1),
                span('Request system monospace','gui',2,0,kind='signal'),
                span('System monospace prepared','fonts',9,0,kind='signal'),
                span('System monospace adopted','gui',9.8,0,kind='signal')]}
            if wake is not None:data['events'][2]['wait']={'reason':wake}
            run=profile.analyze_run(data);model=run['call_graph'];nodes={n['id']:n for n in model['nodes']}
            path=model['paths']['ready'];counted=[nodes[key] for key in path['node_ids']]
            expected=wake in ('other descriptor',None)
            self.assertEqual(any(n['track']=='fonts' for n in counted),expected)
            self.assertEqual(sum(n['duration_ns'] for n in counted),10_000_000)
            self.assertFalse(any(nodes[key]['track']=='fonts' for key in model['paths']['viewport']['node_ids']))

    def test_worker_finishing_during_gui_work_does_not_enter_critical_sum(self):
        data={'profile_version':1,'metrics':{'first_document_ms':2,'first_frame_ms':10},'events':[
            span('Draw window','gui',0,9),span('Accept document and prepared workers','gui',9,.8),
            span('Adopt system Sans fallback and reflow missing glyphs','gui',9.1,.5,1),
            span('Prepare deferred system Sans fallback','fallback',2.1,4.9),
            span('Request system Sans fallback','gui',2,0,kind='signal'),
            span('System Sans fallback prepared','fallback',7,0,kind='signal'),
            span('System Sans fallback adopted','gui',9.7,0,kind='signal')]}
        model=profile.analyze_run(data)['call_graph'];nodes={n['id']:n for n in model['nodes']}
        counted=[nodes[key] for key in model['paths']['ready']['node_ids']]
        self.assertTrue(any(n['track']=='fallback' for n in model['nodes']))
        self.assertFalse(any(n['track']=='fallback' for n in counted))
        self.assertEqual(sum(n['duration_ns'] for n in counted),10_000_000)

    def test_keyboard_preparation_has_its_own_lane_and_only_blocks_if_needed(self):
        data={'profile_version':1,'metrics':{'first_document_ms':2,'first_frame_ms':10},'events':[
            span('Draw first viewport','gui',0,2),
            span('Wait for keyboard preparation','gui',2,6,kind='wait'),
            span('Adopt prepared keyboard resources','gui',8,.5),
            span('Prepare keyboard Compose resources','input',.5,3),
            span('Prepare deferred keyboard keymap','input',3.5,4),
            span('Request keyboard preparation','gui',.4,0,kind='signal'),
            span('Keyboard preparation ready','input',7.5,0,kind='signal'),
            span('Keyboard resources adopted','gui',8.5,0,kind='signal')]}
        data['events'][1]['wait']={'reason':'other descriptor'}
        run=profile.analyze_run(data);model=run['call_graph'];nodes={n['id']:n for n in model['nodes']}
        self.assertIn('input',run['thread_summary'])
        self.assertFalse(any(nodes[key]['track']=='input' for key in model['paths']['viewport']['node_ids']))
        self.assertTrue(any(nodes[key]['track']=='input' for key in model['paths']['ready']['node_ids']))
        self.assertEqual(sum(nodes[key]['duration_ns'] for key in model['paths']['ready']['node_ids']),10_000_000)

    def test_parallel_worker_finishing_before_wait_is_not_counted(self):
        data={'profile_version':1,'metrics':{'first_frame_ms':10},'events':[
            span('Draw window','gui',0,5),span('Wait for system monospace','gui',5,4,kind='wait'),
            span('Accept document and prepared workers','gui',9,.8),
            span('Adopt system monospace and reflow code','gui',9.1,.5,1),
            span('Prepare deferred system monospace','fonts',1.1,2.9),
            span('Request system monospace','gui',1,0,kind='signal'),
            span('System monospace prepared','fonts',4,0,kind='signal'),
            span('System monospace adopted','gui',9.7,0,kind='signal')]}
        model=profile.analyze_run(data)['call_graph'];nodes={n['id']:n for n in model['nodes']}
        self.assertFalse(any(nodes[key]['track']=='fonts' for key in model['paths']['ready']['node_ids']))

    def test_overlap_counts_threads_once_and_excludes_waits(self):
        concurrency = profile.analyze_run(fixture())["concurrency"]
        self.assertEqual(concurrency, {"one_thread_ms": 5, "overlap_ms": 5,
                                       "wait_or_untraced_ms": 10, "gui_wait_ms": 10})
        data = fixture()
        data["events"].append(span("worker during GUI wait", "document", 12, 4))
        concurrency = profile.analyze_run(data)["concurrency"]
        self.assertEqual(concurrency["overlap_ms"], 5)
        self.assertEqual(concurrency["one_thread_ms"], 9)
        self.assertEqual(concurrency["wait_or_untraced_ms"], 6)

    def test_nested_os_wait_is_excluded_from_its_callers_work(self):
        data = fixture()
        data["events"] = [span("dispatch", "gui", 0, 10),
                          span("select wait", "gui", 2, 6, 1, kind="wait"),
                          span("worker", "document", 3, 5)]
        run = profile.analyze_run(data)
        self.assertEqual(run["concurrency"]["overlap_ms"], 0)
        self.assertEqual(run["concurrency"]["gui_wait_ms"], 6)
        self.assertEqual(run["thread_summary"]["gui"],
                         {"work_ms": 4, "wait_ms": 6, "idle_ms": 0, "untraced_ms": 10})

    def test_every_thread_lane_accounts_for_the_entire_launch(self):
        run = profile.analyze_run(fixture())
        for track, totals in run["thread_summary"].items():
            self.assertEqual(sum(totals.values()), 20)
            roots = [event for event in run["events"] if event["track"] == track and
                     event["kind"] != "signal" and event["parent"] is None]
            states = [event for event in run["gaps"] if event["track"] == track]
            cursor = 0
            for event in sorted(roots + states, key=lambda event: event["start_ns"]):
                self.assertEqual(event["start_ns"], cursor)
                cursor += event["duration_ns"]
            self.assertEqual(cursor, 20_000_000)

    def test_worker_idle_states_follow_request_and_ready_signals(self):
        data = fixture()
        data["metrics"].update({"first_document_ms": 12})
        data["events"].extend([span("Request document", "gui", .5, 0, kind="signal"),
                               span("Document ready", "document", 8, 0, kind="signal"),
                               span("Request navigation", "gui", 12.1, 0, kind="signal"),
                               span("prepare navigation", "navigation", 12.2, 2.8),
                               span("Navigation ready", "navigation", 15, 0, kind="signal")])
        run = profile.analyze_run(data)
        states = {(event["track"], event["name"]): event for event in run["gaps"]}
        self.assertEqual(states[("document", "Not requested yet")]["duration_ns"], 500_000)
        self.assertEqual(states[("document", "Idle — document ready")]["duration_ns"], 12_000_000)
        self.assertEqual(states[("navigation", "Deferred — first viewport")]["duration_ns"], 12_000_000)
        self.assertEqual(states[("navigation", "Idle — navigation ready")]["duration_ns"], 5_000_000)
        self.assertTrue(all(event["recorded"] is False for event in run["gaps"]))

    def test_unknown_gaps_are_not_mislabeled_as_waits(self):
        run = profile.analyze_run(fixture())
        self.assertTrue(run["gaps"])
        self.assertTrue(all(event["kind"] == "untraced" for event in run["gaps"]))

    def test_child_row_gaps_are_identified_as_caller_self_time(self):
        run = profile.analyze_run(fixture())
        parent = next(event for event in run["events"] if event["name"] == "GUI")
        spans = [event for event in run["self_spans"] if event["parent"] == parent["id"]]
        self.assertEqual([(event["start_ns"], event["duration_ns"]) for event in spans],
                         [(0, 2_000_000), (6_000_000, 4_000_000)])
        self.assertEqual(sum(event["duration_ns"] for event in spans), parent["self_ns"])

    def test_overlap_for_three_threads_and_out_of_order_events(self):
        data = fixture()
        data["events"].append(span("font preparation", "fonts", 4, 3))
        data["events"].reverse()
        self.assertEqual(profile.analyze_run(data)["concurrency"]["overlap_ms"], 5)

    def test_incomplete_worker_span_is_clipped_at_ready_frame(self):
        data = fixture()
        data["events"].append(span("late worker", "document", 18, 7))
        data["events"].append(span("after readiness", "document", 23, 1))
        run = profile.analyze_run(data)
        self.assertFalse(any(event["name"] == "after readiness" for event in run["events"]))
        self.assertEqual(sum(run["concurrency"][key] for key in ("one_thread_ms", "overlap_ms", "wait_or_untraced_ms")), 20)

    def test_statistics_use_nearest_rank_and_median(self):
        stats = profile.timing_stats([5, 1, 4, 2, 3])
        self.assertEqual({key: stats[key] for key in ("min_ms", "median_ms", "p95_ms", "max_ms")},
                         {"min_ms": 1, "median_ms": 3, "p95_ms": 5, "max_ms": 5})
        self.assertEqual(stats["mean_ms"], 3)
        self.assertEqual(stats["count"], 5)
        self.assertAlmostEqual(stats["margin_95_ms"], 1.963243, places=5)
        self.assertEqual(profile.timing_stats([8])["median_ms"], 8)

    def test_mean_and_error_include_outliers_and_need_repeated_runs(self):
        stats = profile.timing_stats([1, 1, 1, 1, 101])
        self.assertEqual(stats["mean_ms"], 21)
        self.assertEqual(stats["median_ms"], 1)
        self.assertAlmostEqual(stats["margin_95_ms"], 55.5289)
        self.assertIsNone(profile.timing_stats([8])["margin_95_ms"])
        self.assertEqual(profile.timing_stats([8, 8])["margin_95_ms"], 0)
        self.assertAlmostEqual(profile.timing_stats([0, 2])["margin_95_ms"], 12.706205)
        self.assertAlmostEqual(profile.timing_stats(range(100))["margin_95_ms"], 5.756509, places=5)

    def test_three_document_orders_balance_positions_and_predecessors(self):
        orders = profile.launch_orders(3, 12, 123)
        self.assertEqual(orders, profile.launch_orders(3, 12, 123))
        self.assertNotEqual(orders, profile.launch_orders(3, 12, 456))
        for cycle in (orders[:6], orders[6:]):
            self.assertEqual(len(set(cycle)), 6)
            for document in range(3):
                self.assertEqual([sum(order[position] == document for order in cycle) for position in range(3)], [2, 2, 2])
                for other in range(3):
                    if other != document:
                        self.assertEqual(sum((document, other) == pair for order in cycle for pair in zip(order, order[1:])), 2)
        self.assertTrue(all(sorted(order) == [0, 1, 2] for order in profile.launch_orders(3, 5, 123)))
        self.assertEqual(profile.launch_orders(1, 3, 1), [(0,)] * 3)
        self.assertEqual(set(profile.launch_orders(2, 2, 1)), {(0, 1), (1, 0)})
        with self.assertRaises(ValueError):
            profile.launch_orders(0, 1, 1)

    def test_cli_defaults_to_twelve_runs_of_all_three_samples(self):
        with mock.patch.object(profile.sys, "argv", ["profile.py", "--seed", "11"]), \
             mock.patch.object(profile, "profile") as measure:
            self.assertEqual(profile.main(), 0)
        self.assertEqual([path.name for path in measure.call_args.args[1]], ["SAMPLE-SMALL.md", "SAMPLE.md", "SAMPLE-HUGE.md"])
        self.assertEqual(measure.call_args.args[2], 12)
        self.assertEqual(measure.call_args.kwargs, {"seed": 11})

    def test_parallel_groups_keep_distinct_threads_and_nested_call_parents(self):
        run = profile.analyze_run(fixture())
        self.assertEqual(run["parallel_groups"], [{"start_ns": 3_000_000, "duration_ns": 5_000_000,
                                                    "tracks": ["document", "gui"]}])
        calls = {event["name"]: event for event in run["events"]}
        self.assertEqual(calls["child"]["parent"], calls["GUI"]["id"])
        self.assertEqual(calls["grandchild"]["parent"], calls["child"]["id"])
        self.assertEqual(calls["worker child"]["parent"], calls["worker"]["id"])
        self.assertIsNone(calls["worker"]["parent"])
        self.assertEqual(sum(item["duration_ns"] for item in run["activity"]), 20_000_000)

    def test_readiness_signals_do_not_count_as_work_or_change_nesting(self):
        data = fixture()
        data["events"].append(span("Document ready", "document", 7, 0, kind="signal"))
        run = profile.analyze_run(data)
        self.assertEqual(run["concurrency"], profile.analyze_run(fixture())["concurrency"])
        event = next(event for event in run["events"] if event["kind"] == "signal")
        self.assertIsNone(event["parent"])
        self.assertEqual(event["self_ns"], 0)

    def test_dependencies_use_recorded_handoffs_and_identify_the_last_gate(self):
        for document_ready, blocker, delay in ((7, "Scaffold presented", 1), (11, "Document ready", 3)):
            data = fixture()
            data["metrics"].update({"scaffold_ms": 8, "first_document_ms": 12})
            for name, track, at in (("Request document", "gui", .5), ("Document ready", "document", document_ready),
                                    ("Accept document", "gui", max(8, document_ready) + .2),
                                    ("Request navigation", "gui", 12.1), ("Navigation ready", "navigation", 15),
                                    ("Accept navigation", "gui", 15.4)):
                data["events"].append(span(name, track, at, 0, kind="signal"))
            dependencies = profile.analyze_run(data)["dependencies"]
            gate, navigation = dependencies["gates"]
            self.assertEqual((gate["blocked_by"], gate["duration_ns"], gate["pickup_ns"]),
                             (blocker, delay * 1_000_000, 200_000))
            self.assertEqual(navigation["duration_ns"], 2_900_000)
            self.assertEqual(navigation["pickup_ns"], 400_000)
            self.assertIn({"from": "viewport", "to": "navigation", "kind": "deferred"}, dependencies["edges"])
            self.assertGreaterEqual(dependencies["navigation_requested_ns"], 12_000_000)
            self.assertEqual(dependencies["critical_path"], ["start", "scaffold" if document_ready == 7 else "document",
                                                            "accept", "viewport", "navigation", "ready"])

    def test_overlapping_work_alone_does_not_invent_blockers(self):
        dependencies = profile.analyze_run(fixture())["dependencies"]
        self.assertEqual(dependencies, {"nodes": [], "edges": [], "gates": []})

    def test_eager_navigation_and_image_work_have_real_parallel_handoffs(self):
        data = fixture()
        data['startup_policy'] = 'eager-preparation'
        data['metrics'].update({'backend_ms': 6, 'scaffold_ms': 8, 'first_document_ms': 8})
        marks = [('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
                 ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
                 ('Request image decoding','gui',7),('Images ready','images',14),('Accept images','gui',14.1)]
        data['events'].extend(span(name,track,at,0,kind='signal') for name,track,at in marks)
        data['events'].extend([span('prepare navigation','navigation',5.2,1.5),span('decode pixels','images',7.1,6.8)])
        run = profile.analyze_run(data)
        deps = run['dependencies']
        self.assertEqual(deps['policy'],'eager-preparation')
        self.assertIn({'from':'navigation-request','to':'navigation','kind':'dispatch'},deps['edges'])
        self.assertIn({'from':'images','to':'images-accept','kind':'gate'},deps['edges'])
        self.assertFalse(any(edge['from']=='viewport' and edge['to']=='navigation' for edge in deps['edges']))
        self.assertFalse(any(edge['from']=='scaffold' and edge['to']=='accept' for edge in deps['edges']))
        self.assertIn('images',deps['critical_path'])
        self.assertNotIn('viewport',deps['critical_path'])
        positions = {node['id']:node['at_ns'] for node in deps['nodes']}
        self.assertTrue(all(positions[edge['from']]<=positions[edge['to']] for edge in deps['edges']))
        self.assertIn('images',run['thread_summary'])

    def test_eager_worker_that_finishes_before_viewport_does_not_delay_it(self):
        data=fixture()
        data['startup_policy']='eager-preparation'
        data['metrics'].update({'backend_ms':6,'scaffold_ms':8,'first_document_ms':8})
        for name,track,at in [('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
                              ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
                              ('Request image decoding','gui',7),('Images ready','images',7.8),('Accept images','gui',8.3)]:
            data['events'].append(span(name,track,at,0,kind='signal'))
        deps=profile.analyze_run(data)['dependencies']
        self.assertIn('viewport',deps['critical_path'])
        self.assertNotIn('images',deps['critical_path'])

    def test_ready_optional_content_can_be_part_of_one_initial_frame(self):
        data=fixture()
        data['startup_policy']='eager-preparation'
        data['metrics'].update({'backend_ms':6,'scaffold_ms':10,'first_document_ms':10,'first_frame_ms':10})
        for name,track,at in [('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
                              ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
                              ('Request image decoding','gui',7),('Images ready','images',7.8),('Accept images','gui',8.3)]:
            data['events'].append(span(name,track,at,0,kind='signal'))
        deps=profile.analyze_run(data)['dependencies']
        self.assertFalse(any(node['id'] in ('scaffold','viewport') for node in deps['nodes']))
        self.assertTrue(any(node['id']=='ready' and 'First window' in node['label'] for node in deps['nodes']))
        positions={node['id']:node['at_ns'] for node in deps['nodes']}
        self.assertTrue(all(positions[edge['from']]<=positions[edge['to']] for edge in deps['edges']))
        self.assertEqual(deps['critical_path'][-1],'ready')

    def test_system_monospace_is_a_post_viewport_gate_on_its_own_track(self):
        data=fixture()
        data['startup_policy']='eager-preparation'
        data['metrics'].update({'backend_ms':6,'scaffold_ms':8,'first_document_ms':8,
                              'monospace_status':'ready','monospace_request_ms':8.1,
                              'monospace_adopted_ms':18.6,'monospace_frame_ms':20})
        marks=[('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
               ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
               ('Request image decoding','gui',7),('Images ready','images',14),('Accept images','gui',14.1),
               ('Request system monospace','gui',8.1),('System monospace prepared','fonts',18.5),
               ('System monospace adopted','gui',18.6)]
        data['events'].extend(span(name,track,at,0,kind='signal') for name,track,at in marks)
        data['events'].append(span('Prepare deferred system monospace','fonts',8.2,10.3))
        run=profile.analyze_run(data)
        deps=run['dependencies']
        self.assertIn({'from':'viewport','to':'monospace-request','kind':'deferred'},deps['edges'])
        self.assertFalse(any(e['from'].startswith('monospace') and e['to']=='viewport' for e in deps['edges']))
        self.assertIn('monospace',deps['critical_path'])
        self.assertTrue(any(g['track']=='fonts' and g['name']=='Deferred — first viewport' for g in run['gaps']))
        positions={n['id']:n['at_ns'] for n in deps['nodes']}
        self.assertTrue(all(positions[e['from']]<=positions[e['to']] for e in deps['edges']))
        self.assertEqual(run['wall_accounting']['total_ns'],20_000_000)

        # The launcher adds pre-main time to the font milestones too.
        data['main_started_ns']=1_005_000_000
        shifted=profile.include_process_launch(data,1_000_000_000,1_040_000_000)
        self.assertEqual(shifted['metrics']['monospace_request_ms'],13.1)
        self.assertEqual(shifted['metrics']['monospace_adopted_ms'],23.6)
        self.assertEqual(shifted['metrics']['monospace_frame_ms'],25)

    def test_missing_or_early_monospace_does_not_hide_the_later_image_gate(self):
        for available in (False,True):
            data=fixture();data['startup_policy']='eager-preparation'
            data['metrics'].update({'backend_ms':6,'scaffold_ms':8,'first_document_ms':8,
                                  'monospace_status':'ready' if available else 'unavailable',
                                  'monospace_frame_ms':12})
            marks=[('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
                   ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
                   ('Request image decoding','gui',7),('Images ready','images',18),('Accept images','gui',18.1),
                   ('Request system monospace','gui',8.1),('System monospace prepared','fonts',10),
                   ('System monospace adopted' if available else 'System monospace unavailable','gui',11)]
            data['events'].extend(span(name,track,at,0,kind='signal') for name,track,at in marks)
            deps=profile.analyze_run(data)['dependencies']
            self.assertIn('images',deps['critical_path'])
            self.assertNotIn('monospace',deps['critical_path'])
            self.assertEqual(any(n['id']=='monospace-frame' for n in deps['nodes']),available)
            positions={n['id']:n['at_ns'] for n in deps['nodes']}
            self.assertTrue(all(positions[e['from']]<=positions[e['to']] for e in deps['edges']))

    def test_sans_and_mono_workers_have_independent_post_viewport_gates(self):
        for last in ('fallback','monospace'):
            data=fixture();data['startup_policy']='eager-preparation'
            data['metrics'].update({'backend_ms':6,'scaffold_ms':8,'first_document_ms':8,
                                   'monospace_status':'ready','fallback_status':'ready',
                                   'monospace_frame_ms':20,'fallback_frame_ms':20})
            marks=[('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
                   ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2)]
            for key,track,label in [('monospace','fonts','System monospace'),('fallback','fallback','System Sans fallback')]:
                end=18 if key==last else 12
                marks.extend([('Request '+label[0].lower()+label[1:],'gui',8.1),
                              (label+' prepared',track,end),(label+' adopted','gui',end+.1)])
                data['events'].append(span('Prepare '+label,track,8.2,end-8.2))
            data['events'].extend(span(name,track,at,0,kind='signal') for name,track,at in marks)
            run=profile.analyze_run(data);deps=run['dependencies']
            self.assertIn(last,deps['critical_path'])
            other='monospace' if last=='fallback' else 'fallback'
            self.assertNotIn(other,deps['critical_path'])
            positions={n['id']:n['at_ns'] for n in deps['nodes']}
            self.assertTrue(all(positions[e['from']]<=positions[e['to']] for e in deps['edges']))
            self.assertEqual(run['wall_accounting']['total_ns'],20_000_000)
            self.assertTrue(any(g['track']=='fallback' and g['name']=='Deferred — first viewport' for g in run['gaps']))
        data['main_started_ns']=1_005_000_000
        data['metrics'].update(fallback_request_ms=8.1,fallback_adopted_ms=12.1,fallback_frame_ms=20)
        shifted=profile.include_process_launch(data,1_000_000_000,1_040_000_000)
        self.assertEqual(shifted['metrics']['fallback_request_ms'],13.1)
        self.assertEqual(shifted['metrics']['fallback_adopted_ms'],17.1)
        self.assertEqual(shifted['metrics']['fallback_frame_ms'],25)

    def test_unicode_diagram_redraw_depends_on_prepared_fallback_fonts(self):
        data=fixture();data['startup_policy']='eager-preparation'
        data['metrics'].update(backend_ms=6,scaffold_ms=8,first_document_ms=8,
                               fallback_status='ready',fallback_frame_ms=12)
        marks=[('Request document','gui',.5),('Document ready','document',2),('Accept document','gui',5),
               ('Request navigation','gui',5.1),('Navigation ready','navigation',6.8),('Accept navigation','gui',8.2),
               ('Request image decoding','gui',6.9),('Images ready','images',7.5),('Accept images','gui',8.3),
               ('Request system Sans fallback','gui',8.1),('System Sans fallback prepared','fallback',11),
               ('System Sans fallback adopted','gui',11.1),('Request image decoding','gui',11.2),
               ('Images ready','images',18),('Accept images','gui',18.1)]
        data['events'].extend(span(name,track,at,0,kind='signal') for name,track,at in marks)
        data['events'].append(span('Map prepared fallback fonts for diagram labels','images',11.3,.1))
        deps=profile.analyze_run(data)['dependencies']
        self.assertIn({'from':'fallback-adopt','to':'images-request','kind':'gate'},deps['edges'])
        self.assertEqual(deps['critical_path'][-5:],['fallback-adopt','images-request','images','images-accept','ready'])
        self.assertTrue(any(n['id']=='images-request' and n['at_ns']==11_200_000 for n in deps['nodes']))

    def test_invalid_profile_does_not_produce_statistics(self):
        for key, value in (("profile_version", 2), ("events", [])):
            data = fixture()
            data[key] = value
            with self.assertRaises(ValueError):
                profile.analyze_run(data)
        data = fixture()
        data["events"][0]["duration_ns"] = -1
        with self.assertRaises(ValueError):
            profile.analyze_run(data)

    def test_report_is_offline_and_escapes_script_delimiters(self):
        report = {"runs": [profile.analyze_run(fixture())], "document": "</script><script>bad()</script>"}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "profile.html"
            profile.write_report(report, output)
            html = output.read_text()
            self.assertNotIn(report["document"], html)
            self.assertNotIn("__PROFILE_DATA__", html)
            self.assertNotRegex(html, r'<(?:script|link)[^>]+(?:src|href)=["\']https?://')
            payload = re.search(r'<script id="profile-data" type="application/json">(.*?)</script>', html, re.S).group(1)
            self.assertEqual(json.loads(payload), report)
            self.assertEqual(list(Path(directory).iterdir()), [output])

    def test_archived_report_gets_graph_without_changing_recorded_timings(self):
        data = fixture()
        data['metrics']['first_document_ms'] = 5
        data['events'][1]['duration_ns'] = 7_000_000
        run = profile.analyze_run(data)
        del run['call_graph']
        original = json.dumps({'metrics': run['metrics'], 'events': run['events']}, sort_keys=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'profile.html'
            profile.write_report({'documents': [{'runs': [run]}]}, output)
            payload = re.search(r'<script id="profile-data" type="application/json">(.*?)</script>',
                                output.read_text(), re.S).group(1)
            saved = json.loads(payload)['documents'][0]['runs'][0]
        self.assertEqual(json.dumps({'metrics': saved['metrics'], 'events': saved['events']}, sort_keys=True), original)
        model = saved['call_graph']
        nodes = {node['id']: node for node in model['nodes']}
        for endpoint, total in [('viewport', 5_000_000), ('ready', 20_000_000)]:
            self.assertEqual(sum(nodes[key]['duration_ns'] for key in model['paths'][endpoint]['node_ids']), total)
        # A child that crosses the viewport is split without changing its source span.
        child = next(event for event in saved['events'] if event['name'] == 'child')
        rows = [row for node in nodes.values() for row in node['rows'] if row['event_id'] == child['id']]
        self.assertEqual(child['duration_ns'], 7_000_000)
        self.assertEqual([(row['start_ns'], row['duration_ns'], row['clipped']) for row in rows],
                         [(2_000_000, 3_000_000, True), (5_000_000, 4_000_000, True)])

    def test_nonpositive_launch_count_fails_before_execution(self):
        result = subprocess.run([sys.executable, str(root / "scripts/profile.py"), "--runs", "0"], capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_timestamped_artifact_sets_preserve_existing_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "profile.html"
            now = datetime(2026, 10, 17, 18, 30, 45, 123456, tzinfo=timezone.utc)
            first = profile.timestamped_output(base, now)
            self.assertEqual(first.name, "profile-20261017T183045.123456Z.html")
            first.with_suffix(".json").write_text("previous measurements")
            second = profile.timestamped_output(base, now)
            self.assertNotEqual(first, second)
            self.assertEqual(first.with_suffix(".json").read_text(), "previous measurements")

    def test_kernel_cache_reset_syncs_before_the_exact_privileged_write(self):
        order = []
        def reset(command, **kwargs):
            order.append("reset")
            self.assertEqual(command, ["/usr/bin/sudo", "-n", "/usr/bin/tee", "/proc/sys/vm/drop_caches"])
            self.assertEqual(kwargs["input"], "3\n")
            return subprocess.CompletedProcess(command, 0, "3\n", "")
        with mock.patch.object(profile.os, "sync", side_effect=lambda: order.append("sync")), \
                mock.patch.object(profile.os, "geteuid", return_value=1000), \
                mock.patch.object(profile.shutil, "which", return_value="/usr/bin/sudo"), \
                mock.patch.object(profile.subprocess, "run", side_effect=reset):
            result = profile.drop_linux_caches()
        self.assertEqual(order, ["sync", "reset"])
        self.assertTrue(result["success"])
        self.assertEqual(result["drop_caches"], 3)

    def test_failed_cache_reset_never_launches_or_replaces_a_report(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "profile.html"
            base.write_text("previous report")
            with mock.patch.object(profile, "require_wayland_session"), \
                    mock.patch.object(profile, "drop_linux_caches", side_effect=RuntimeError("not permitted")), \
                    mock.patch.object(profile.subprocess, "run") as launch:
                with self.assertRaises(RuntimeError):
                    profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 2, base)
                launch.assert_not_called()
            self.assertEqual(base.read_text(), "previous report")
            self.assertEqual(list(Path(directory).iterdir()), [base])

    def test_file_specific_flush_precedes_the_same_kernel_cache_reset(self):
        order = []
        def drop(command, **kwargs):
            order.append('drop')
            self.assertEqual(command, ['/usr/bin/sudo','-n','/usr/bin/tee','/proc/sys/vm/drop_caches'])
            self.assertEqual(kwargs['input'], '3\n')
            return subprocess.CompletedProcess(command,0,'3\n','')
        with tempfile.TemporaryDirectory() as directory:
            first,second=Path(directory)/'mdf',Path(directory)/'sample.md'
            first.write_text('binary');second.write_text('document')
            with mock.patch.object(profile.os,'sync') as global_sync, \
                 mock.patch.object(profile.os,'fsync',side_effect=lambda fd:order.append('fsync')), \
                 mock.patch.object(profile.os,'geteuid',return_value=1000), \
                 mock.patch.object(profile.shutil,'which',return_value='/usr/bin/sudo'), \
                 mock.patch.object(profile.subprocess,'run',side_effect=drop):
                result=profile.drop_linux_caches(flush_paths=[first,second,first])
            global_sync.assert_not_called()
            self.assertEqual(order,['fsync','fsync','drop'])
            self.assertEqual(result['drop_caches'],3)
            self.assertFalse(result['sync'])

    def test_warm_image_aborts_even_when_the_executable_is_cold(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);doc=base/'sample.md';image=base/'image.png'
            doc.write_text('![image](image.png)');image.write_bytes(b'fixture')
            def state(path):
                return {'resident_pages':1 if path==image else 0,'total_pages':1}
            with mock.patch.object(profile,'require_wayland_session'), \
                 mock.patch.object(profile,'drop_linux_caches',return_value={'success':True}), \
                 mock.patch.object(profile,'binary_cache_state',side_effect=state), \
                 mock.patch.object(profile.subprocess,'run') as launch:
                with self.assertRaisesRegex(RuntimeError,'1/1 pages resident'):
                    profile.profile(base/'mdf',doc,1,base/'report.html')
                launch.assert_not_called()

    def test_every_measured_launch_has_a_reset_and_a_unique_empty_cache(self):
        data = fixture()
        data.update({"version": "test", "mode": "ReleaseFast", "renderer": "opengl", "video_driver": "wayland"})
        data["metrics"].update({"blocks": 1, "first_document_ms": 12})
        order, caches = [], []
        def reset(*, flush_paths):
            self.assertEqual(flush_paths[0], Path('/not/executed'))
            self.assertIn(Path('SAMPLE.md'), flush_paths)
            order.append("reset")
            return {"success": True, "drop_caches": 3}
        def verify(binary):
            order.append("verify" if binary == Path('/not/executed') else "verify-input")
            return {"resident_pages": 0, "total_pages": 1, "verified_cold": True}
        def launch(command, **kwargs):
            order.append("launch")
            cache = Path(kwargs["env"]["XDG_CACHE_HOME"])
            self.assertEqual(list(cache.iterdir()), [])
            self.assertEqual(kwargs["env"]["MESA_SHADER_CACHE_DISABLE"], "true")
            self.assertEqual(kwargs["env"]["__GL_SHADER_DISK_CACHE"], "0")
            self.assertEqual(kwargs["env"]["FLTK_BACKEND"], "wayland")
            self.assertNotIn("WAYLAND_SOCKET", kwargs["env"])
            caches.append(cache)
            data["main_started_ns"] = (len(caches) - 1) * 100_000_000 + 1_000_000
            return subprocess.CompletedProcess(command, 0, json.dumps(data), "")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "profile" / "profile.html"
            with mock.patch.object(profile, "require_wayland_session"), \
                    mock.patch.object(profile, "drop_linux_caches", side_effect=reset), \
                    mock.patch.object(profile, "verify_cold_binary", side_effect=verify), \
                    mock.patch.object(profile, "project_context", return_value={}), \
                    mock.patch.object(profile.platform, "platform", return_value="Test Linux"), \
                    mock.patch.object(profile.time, "monotonic_ns", side_effect=[value for i in range(3) for value in (i * 100_000_000, i * 100_000_000 + 40_000_000)]), \
                    mock.patch.object(profile.subprocess, "run", side_effect=launch):
                report = profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 3, output)
            input_count = len(profile.cold_input_paths(Path('/not/executed'), Path('SAMPLE.md')))-1
            self.assertEqual(order, ["reset", "verify", *["verify-input"]*input_count, "launch"] * 3)
            self.assertEqual(len(set(caches)), 3)
            self.assertTrue(all(not cache.exists() for cache in caches))
            self.assertEqual(len(list(output.parent.iterdir())), 1)
            self.assertEqual(report["documents"][0]["statistics"]["median_ms"], 13)

    def test_three_documents_have_all_run_averages_and_balanced_cold_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            documents = [base / "SAMPLE-SMALL.md", base / "SAMPLE.md", base / "SAMPLE-HUGE.md"]
            for index, document in enumerate(documents):
                document.write_text(("# " + document.stem + "\n") * (index + 1))
            launches, caches, resets = [], [], []
            def launch(command, **kwargs):
                launches.append(Path(command[-1]).name)
                cache = Path(kwargs["env"]["XDG_CACHE_HOME"])
                self.assertEqual(list(cache.iterdir()), [])
                caches.append(cache)
                data = fixture()
                huge = launches[-1] == "SAMPLE-HUGE.md"
                data.update({"version": "test", "mode": "ReleaseFast", "video_driver": "wayland", "renderer": "cairo",
                             "main_started_ns": (len(launches) - 1) * 200_000_000 + 10_000_000})
                data["metrics"].update({"first_document_ms": 70 if huge else 12, "first_frame_ms": 90 if huge else 20})
                return subprocess.CompletedProcess(command, 0, json.dumps(data), "")
            with mock.patch.object(profile, "require_wayland_session"), \
                    mock.patch.object(profile, "drop_linux_caches", side_effect=lambda **kwargs: resets.append(True) or {"success": True}), \
                    mock.patch.object(profile, "verify_cold_binary", return_value={"resident_pages": 0, "total_pages": 1, "verified_cold": True}), \
                    mock.patch.object(profile, "project_context", return_value={}), \
                    mock.patch.object(profile.platform, "platform", return_value="Test Linux"), \
                    mock.patch.object(profile.time, "monotonic_ns", side_effect=[value for i in range(36) for value in (i * 200_000_000, i * 200_000_000 + 150_000_000)]), \
                    mock.patch.object(profile.subprocess, "run", side_effect=launch):
                report = profile.profile(base / "mdf", documents, 12, base / "output/profile.html", seed=123)
            self.assertEqual(launches, [documents[i].name for order in profile.launch_orders(3, 12, 123) for i in order])
            self.assertEqual(report["experiment"]["round_orders"], [launches[i:i+3] for i in range(0, 36, 3)])
            self.assertEqual(report["experiment"]["seed"], "123")
            self.assertEqual(len(resets), 36)
            self.assertEqual(len(set(caches)), 36)
            self.assertTrue(all(not path.exists() for path in caches))
            self.assertEqual([len(item["runs"]) for item in report["documents"]], [12, 12, 12])
            self.assertEqual([item["statistics"]["mean_ms"] for item in report["documents"]], [22, 22, 80])
            self.assertEqual([item["statistics"]["margin_95_ms"] for item in report["documents"]], [0, 0, 0])
            self.assertEqual([item["pre_main_statistics"]["median_ms"] for item in report["documents"]], [10, 10, 10])
            for item in report["documents"]:
                for run in item["runs"]:
                    sequence = run["launch_sequence"]
                    self.assertEqual(launches[sequence["launch"] - 1], Path(item["document"]).name)
                    self.assertEqual(sequence["launch"], (sequence["round"] - 1) * 3 + sequence["position"])
            self.assertNotEqual(report["documents"][0]["input"]["sha256"], report["documents"][1]["input"]["sha256"])
            self.assertEqual(len(list((base / "output").iterdir())), 1)
            self.assertNotIn("runs", report)  # Shared build metadata is stored only once.

    def test_library_inventory_uses_file_sizes_without_embedding_sources_or_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "frontend").mkdir()
            (project / "frontend/dependencies.json").write_bytes((root / "frontend/dependencies.json").read_bytes())
            (project / "build.zig.zon").write_bytes((root / "build.zig.zon").read_bytes())
            (project / "src").mkdir()
            (project / "src/private.zig").write_text("SOURCE_MUST_NOT_BE_EMBEDDED")
            sdk = project / "build/fltk/ReleaseFast/lib"
            sdk.mkdir(parents=True)
            (sdk / "libfltk.a").write_bytes(b"fltk archive")
            binary = project / "mdf"
            binary.write_bytes(b"binary")
            (project / "libmdf-extra.so").write_bytes(b"retired compatibility library")
            document = project / "SAMPLE.md"
            document.write_text("SAMPLE_MUST_NOT_BE_EMBEDDED")
            shared = project / "libcairo.so.2"
            shared.write_bytes(b"actual shared library size")
            def command(arguments, **kwargs):
                return f"libcairo.so.2 => {shared} (0x1234)" if arguments[0] == "ldd" else "1.2.3"
            size_map = {"children": [{"name": "Bundled libraries", "children": [{"name": "FLTK", "bytes": 5}, {"name": "MD4C", "bytes": 2}]}]}
            with mock.patch.object(profile, "command_output", side_effect=command), \
                    mock.patch.object(profile, "binary_breakdown", return_value=size_map):
                context = profile.project_context(project, binary, document, {"version": "test", "mode": "ReleaseFast"})
            libraries = {lib["name"]: lib for lib in context["libraries"]}
            self.assertEqual(context["binaries"], [profile.file_info(binary, "mdf")])
            self.assertNotIn("libmdf-extra.so", json.dumps(context))
            self.assertEqual(libraries["cairo"]["bytes"], shared.stat().st_size)
            self.assertEqual(libraries["cairo"]["size_basis"], "shared library")
            self.assertEqual(libraries["FLTK"]["bytes"], (sdk / "libfltk.a").stat().st_size)
            self.assertEqual(libraries["FLTK"]["linked_bytes"], 5)
            self.assertEqual(libraries["MD4C"]["linked_bytes"], 2)
            self.assertIsNone(libraries["cairo"]["linked_bytes"])
            self.assertEqual(libraries["MD4C"]["size_basis"], "included in executable")
            self.assertNotIn("sources", context)
            self.assertNotIn("SOURCE_MUST_NOT_BE_EMBEDDED", json.dumps(context))
            self.assertNotIn("SAMPLE_MUST_NOT_BE_EMBEDDED", json.dumps(context))
            self.assertNotIn("source_tree_bytes", json.dumps(context))

    def test_missing_wayland_fails_before_any_global_cache_reset_or_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(profile.os.environ, {}, clear=True), \
                    mock.patch.object(profile, "drop_linux_caches") as reset, \
                    mock.patch.object(profile.subprocess, "run") as launch:
                with self.assertRaisesRegex(RuntimeError, "requires a Wayland session"):
                    profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 2, Path(directory) / "profile.html")
                reset.assert_not_called()
                launch.assert_not_called()

    def test_wayland_preflight_resolves_default_named_and_absolute_sockets(self):
        cases = [({"XDG_RUNTIME_DIR": "/tmp/runtime"}, "/tmp/runtime/wayland-0"),
                 ({"XDG_RUNTIME_DIR": "/tmp/runtime", "WAYLAND_DISPLAY": "wayland-2"}, "/tmp/runtime/wayland-2"),
                 ({"WAYLAND_DISPLAY": "/tmp/absolute-wayland"}, "/tmp/absolute-wayland")]
        for environment, expected in cases:
            with mock.patch.object(Path, "is_socket", autospec=True, return_value=True) as probe:
                profile.require_wayland_session(environment)
                probe.assert_called_once_with(Path(expected))
        with mock.patch.object(Path, "is_socket", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "No Wayland display socket"):
                profile.require_wayland_session({"XDG_RUNTIME_DIR": "/tmp/runtime"})

    def test_profile_rejects_other_video_backends_without_writing_a_report(self):
        for driver in ("x11", "dummy"):
            data = fixture()
            data["mode"] = "ReleaseFast"
            data["video_driver"] = driver
            process = subprocess.CompletedProcess([], 0, json.dumps(data), "")
            with tempfile.TemporaryDirectory() as directory:
                with mock.patch.object(profile, "require_wayland_session"), \
                        mock.patch.object(profile, "drop_linux_caches"), \
                        mock.patch.object(profile, "verify_cold_binary", return_value={"verified_cold": True}), \
                        mock.patch.object(profile.subprocess, "run", return_value=process):
                    with self.assertRaisesRegex(RuntimeError, "requires the Wayland video backend"):
                        profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 1, Path(directory) / "profile.html")
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_profile_rejects_nonrelease_builds_without_writing_a_report(self):
        for mode in ("Debug", "ReleaseSafe", "ReleaseSmall", None):
            data = fixture()
            data.update({"mode": mode, "video_driver": "wayland"})
            process = subprocess.CompletedProcess([], 0, json.dumps(data), "")
            with tempfile.TemporaryDirectory() as directory:
                with mock.patch.object(profile, "require_wayland_session"), \
                        mock.patch.object(profile, "drop_linux_caches"), \
                        mock.patch.object(profile, "verify_cold_binary", return_value={"verified_cold": True}), \
                        mock.patch.object(profile.subprocess, "run", return_value=process):
                    with self.assertRaisesRegex(RuntimeError, "requires a ReleaseFast build"):
                        profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 1, Path(directory) / "profile.html")
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_profile_rejects_debug_frontend_with_release_core(self):
        data = fixture()
        data.update({"mode": "ReleaseFast", "gui": "FLTK 1.4.5", "ui_mode": "Debug", "video_driver": "wayland"})
        process = subprocess.CompletedProcess([], 0, json.dumps(data), "")
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(profile, "require_wayland_session"), \
                    mock.patch.object(profile, "drop_linux_caches"), \
                    mock.patch.object(profile, "verify_cold_binary", return_value={"verified_cold": True}), \
                    mock.patch.object(profile.subprocess, "run", return_value=process):
                with self.assertRaisesRegex(RuntimeError, "Release"):
                    profile.profile(Path("/not/executed"), Path("SAMPLE.md"), 1, Path(directory) / "profile.html")
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
