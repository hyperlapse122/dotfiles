import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


# These real native boundary doubles parse argv, persist installed state, and return
# process exit codes. No host installer, registry setting, or user profile is touched.
NATIVE_DOUBLE = r'''
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

public static class VisualStudioDouble {
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static string StatePath { get { return Environment.GetEnvironmentVariable("VS_TEST_STATE"); } }
    static Dictionary<string, object> Read(string path) {
        return (Dictionary<string, object>)Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
    }
    static object[] Items(object value) { return (object[])value; }
    static void Save(Dictionary<string, object> state) {
        File.WriteAllText(StatePath, Json.Serialize(state), new UTF8Encoding(false));
    }
    static string Value(string[] args, string name) {
        int index = Array.IndexOf(args, name);
        return index < 0 ? null : args[index + 1];
    }
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        var state = Read(StatePath);
        string executable = Assembly.GetExecutingAssembly().Location;
        var instances = Items(state["instances"]).Cast<Dictionary<string, object>>().ToList();
        if (Path.GetFileName(executable) == "vswhere.exe") {
            var queries = Items(state["queries"]).ToList();
            queries.Add(args);
            state["queries"] = queries;
            Save(state);
            int discoveryExit = Convert.ToInt32(state["discovery_exit"]);
            if (discoveryExit != 0) return discoveryExit;
            int requires = Array.IndexOf(args, "-requires");
            string[] components = requires < 0 ? new string[0] : args.Skip(requires + 1).ToArray();
            var selected = instances.Where(instance =>
                (string)instance["productId"] == Value(args, "-products") &&
                new Version((string)instance["installationVersion"]) >= new Version("18.0") &&
                new Version((string)instance["installationVersion"]) < new Version("19.0") &&
                !Convert.ToBoolean(instance["isPrerelease"]) &&
                (args.Contains("-all") || Convert.ToBoolean(instance["isComplete"])) &&
                components.All(component => Items(instance["components"]).Contains(component)));
            Console.WriteLine(Json.Serialize(selected.ToArray()));
            return 0;
        }
        string operation = args.Length > 0 && !args[0].StartsWith("--") ? args[0] : "install";
        var calls = Items(state["calls"]).ToList();
        calls.Add(new Dictionary<string, object> {
            {"operation", operation}, {"argv", args}, {"executable", executable}
        });
        state["calls"] = calls;
        Save(state);
        var results = (Dictionary<string, object>)state["results"];
        int exit = results.ContainsKey(operation) ? Convert.ToInt32(results[operation]) : 0;
        if (exit != 0) return exit;
        string installPath = Value(args, "--installPath");
        Dictionary<string, object> target;
        if (operation == "install") {
            target = new Dictionary<string, object> {
                {"instanceId", "new-build-tools"}, {"productId", "Microsoft.VisualStudio.Product.BuildTools"},
                {"channelId", Value(args, "--channelId")}, {"installationVersion", "18.11.3"},
                {"installationPath", installPath}, {"isPrerelease", false},
                {"isComplete", false}, {"components", new object[0]}
            };
            instances.Add(target);
            string discoveryPath = Path.Combine(Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
                @"Microsoft Visual Studio\Installer\vswhere.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(discoveryPath));
            if (!File.Exists(discoveryPath)) File.Copy(executable, discoveryPath);
        } else {
            target = instances.Single(instance => (string)instance["installationPath"] == installPath);
        }
        if (operation == "update") target["installationVersion"] = "18.11.3";
        if ((operation == "install" || operation == "modify") && !Convert.ToBoolean(state["ineffective_config"])) {
            object[] required = Items(Read(Value(args, "--config"))["components"]);
            target["components"] = Items(target["components"]).Concat(required).Distinct().ToArray();
            target["isComplete"] = true;
        }
        state["instances"] = instances;
        Save(state);
        return 0;
    }
}
'''


@unittest.skipUnless(os.name == "nt", "Native Windows Visual Studio provisioning")
class WindowsVisualStudioTest(unittest.TestCase):
    components = (
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "Microsoft.VisualStudio.Component.VC.14.29.16.11.MFC.ARM64",
        "Microsoft.VisualStudio.Component.VC.14.44.17.14.ATL.ARM64",
        "Microsoft.Net.Component.4.8.1.TargetingPack",
    )

    @classmethod
    def setUpClass(cls):
        cls.shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        cls.native_scratch = tempfile.TemporaryDirectory(prefix="visual studio native double ")
        cls.addClassCleanup(cls.native_scratch.cleanup)
        directory = Path(cls.native_scratch.name)
        source = directory / "double.cs"
        source.write_text(NATIVE_DOUBLE, encoding="utf-8-sig")
        cls.double = directory / "double.exe"
        compile_script = directory / "compile.ps1"
        compile_script.write_text(
            "$ErrorActionPreference = 'Stop'\n"
            "Add-Type -Path $args[0] -OutputAssembly $args[1] -OutputType ConsoleApplication "
            "-ReferencedAssemblies System.Web.Extensions,System.Core\n", encoding="utf-8-sig")
        result = subprocess.run(
            [str(cls.shell), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(compile_script), str(source), str(cls.double)],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def setUp(self):
        self.repo = Path(__file__).resolve().parents[1]
        scratch = tempfile.TemporaryDirectory(prefix="VS provisioning 空白 ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.program_files = self.root / "program files"
        self.program_files.mkdir()
        self.program_files_x86 = self.root / "program files x86"
        self.program_files_x86.mkdir()
        self.temp = self.root / "temporary downloads 空白"
        self.temp.mkdir()
        self.install_path = self.program_files / "Build Tools 空白"
        self.config = self.root / "build tools 空白.vsconfig"
        self.config.write_text(json.dumps({"version": "1.0", "components": self.components}), encoding="utf-8")
        self.state_path = self.root / "installed state.json"
        self.state = {
            "instances": [], "calls": [], "queries": [], "results": {},
            "discovery_exit": 0, "ineffective_config": False,
        }
        self.launches = self.root / "launches.jsonl"
        self.wrapper = self.root / "apply.ps1"
        self.wrapper.write_text(r'''
param([string]$Script, [string]$Config, [string]$Root)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if ($Uri -cne 'https://aka.ms/vs/stable/vs_buildtools.exe') { throw 'Unexpected download' }
    Copy-Item -LiteralPath $env:VS_TEST_DOUBLE -Destination $OutFile
}
function Get-AuthenticodeSignature {
    param($LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { throw 'Missing downloaded executable' }
    [pscustomobject]@{
        Status = $env:VS_TEST_SIGNATURE_STATUS
        SignerCertificate = [pscustomobject]@{ Subject = $env:VS_TEST_SIGNER }
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $Verb)
    if (-not $Wait -or -not $PassThru) { throw 'Installer must wait and return its exit code' }
    if ($Verb -and $Verb -ne 'RunAs') { throw 'Unexpected installer verb' }
    [pscustomobject]@{ executable = $FilePath; arguments = $ArgumentList; verb = $Verb } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $env:VS_TEST_LAUNCHES -Encoding UTF8
    # Keep process creation and Windows argv decoding real, but never request elevation.
    Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
}
& $Script -ConfigurationPath $Config -BootstrapperUri 'https://aka.ms/vs/stable/vs_buildtools.exe' `
    -ChannelId 'VisualStudio.18.Stable' -InstallPath $Root
''', encoding="utf-8-sig")
        self.env = os.environ.copy()
        self.env.update({
            "ProgramFiles": str(self.program_files), "ProgramFiles(x86)": str(self.program_files_x86),
            "TEMP": str(self.temp), "TMP": str(self.temp), "VS_TEST_STATE": str(self.state_path),
            "VS_TEST_DOUBLE": str(self.double), "VS_TEST_LAUNCHES": str(self.launches),
            "VS_TEST_SIGNATURE_STATUS": "Valid", "VS_TEST_SIGNER": "CN=Microsoft Corporation, O=Microsoft Corporation, C=US",
        })

    def instance(self, **changes):
        instance = {
            "instanceId": "existing-build-tools", "productId": "Microsoft.VisualStudio.Product.BuildTools",
            "channelId": "VisualStudio.18.Stable", "installationVersion": "18.0.1",
            "installationPath": str(self.install_path), "isPrerelease": False,
            "isComplete": True, "components": list(self.components),
        }
        instance.update(changes)
        return instance

    def provide_discovery(self):
        target = self.program_files_x86 / "Microsoft Visual Studio/Installer/vswhere.exe"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.double, target)

    def apply(self, check=True, discovery=True):
        if discovery:
            self.provide_discovery()
        self.state_path.write_text(json.dumps(self.state), encoding="utf-8")
        result = subprocess.run(
            [str(self.shell), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(self.wrapper), str(self.repo / "scripts/windows-visual-studio.ps1"),
             str(self.config), str(self.install_path)],
            env=self.env, capture_output=True, text=True, encoding="utf-8", errors="backslashreplace", timeout=90,
        )
        self.state = json.loads(self.state_path.read_text(encoding="utf-8"))
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("is ready:", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("is ready:", result.stdout)
        self.assertEqual(list(self.temp.iterdir()), [], "Temporary downloaded bootstrapper was not removed")
        return result

    def operations(self):
        return [call["operation"] for call in self.state["calls"]]

    def test_complete_existing_instance_updates_on_every_apply(self):
        self.state["instances"] = [self.instance()]
        self.apply()
        self.assertEqual(self.operations(), ["update"])
        self.assertEqual(self.state["instances"][0]["installationVersion"], "18.11.3")
        self.apply()
        self.assertEqual(self.operations(), ["update", "update"])

    def test_missing_component_is_added_and_unrelated_components_survive(self):
        self.state["instances"] = [self.instance(components=[*self.components[:-1], "Unrelated.Component"])]
        self.apply()
        self.assertEqual(self.operations(), ["update", "modify"])
        self.assertEqual(set(self.state["instances"][0]["components"]), {*self.components, "Unrelated.Component"})
        queries = self.state["queries"]
        complete_queries = [query for query in queries if "-requires" in query]
        self.assertGreaterEqual(len(complete_queries), 2)
        for query in complete_queries:
            self.assertEqual(query[query.index("-requires") + 1:], list(self.components))
            self.assertNotIn("-all", query)

    def test_partial_registered_instance_is_reconciled_not_reinstalled(self):
        self.state["instances"] = [self.instance(isComplete=False, components=[])]
        self.apply()
        self.assertEqual(self.operations(), ["update", "modify"])
        self.assertEqual(self.state["instances"][0]["instanceId"], "existing-build-tools")
        self.assertTrue(self.state["instances"][0]["isComplete"])

    def test_absence_including_missing_vswhere_installs_and_verifies(self):
        self.apply(discovery=False)
        self.assertEqual(self.operations(), ["install"])
        self.assertEqual(self.state["instances"][0]["components"], list(self.components))
        self.assertTrue(any("-requires" in query for query in self.state["queries"]))

    def test_unrelated_ide_and_preview_are_not_serviced(self):
        ide = self.instance(instanceId="ide", productId="Microsoft.VisualStudio.Product.Enterprise",
                            installationPath=str(self.root / "unrelated IDE"))
        preview = self.instance(instanceId="preview", channelId="VisualStudio.18.Preview", isPrerelease=True,
                                installationPath=str(self.root / "preview"))
        other_channel = self.instance(instanceId="other-channel", channelId="VisualStudio.18.LTSC",
                                      installationPath=str(self.root / "other channel"))
        self.state["instances"] = [ide, preview, other_channel]
        self.apply()
        self.assertEqual(self.operations(), ["install"])
        self.assertEqual(self.state["instances"][:3], [ide, preview, other_channel])

    def test_multiple_stable_instances_fail_without_arbitrary_selection(self):
        self.state["instances"] = [self.instance(), self.instance(instanceId="second", installationPath=str(self.root / "second"))]
        result = self.apply(check=False)
        self.assertIn("Multiple stable", result.stdout + result.stderr)
        self.assertEqual(self.operations(), [])
        self.assertFalse(self.launches.exists())

    def test_invalid_or_wrong_signer_never_executes(self):
        for status, signer in (("NotSigned", "CN=Microsoft Corporation"),
                               ("HashMismatch", "CN=Microsoft Corporation"),
                               ("Valid", "CN=Other Publisher, O=Microsoft Corporation"),
                               ("Valid", "CN=Microsoft Corporation Untrusted")):
            with self.subTest(status=status, signer=signer):
                self.env["VS_TEST_SIGNATURE_STATUS"] = status
                self.env["VS_TEST_SIGNER"] = signer
                result = self.apply(check=False)
                self.assertIn("valid Microsoft Corporation", result.stdout + result.stderr)
                self.assertEqual(self.operations(), [])
                self.assertFalse(self.launches.exists())

    def test_installer_failure_and_reboot_stop_before_dependent_operations(self):
        for code in (23, 1003, 1641, 3010):
            with self.subTest(code=code):
                self.state["instances"] = [self.instance(isComplete=False, components=[])]
                self.state["calls"] = []
                self.state["results"] = {"update": code}
                result = self.apply(check=False)
                diagnostic = result.stdout + result.stderr
                self.assertIn("update", diagnostic)
                self.assertIn(str(code), diagnostic)
                if code == 3010:
                    self.assertIn("reboot required", diagnostic)
                self.assertEqual(self.operations(), ["update"])
                self.assertFalse(self.state["instances"][0]["isComplete"])

    def test_install_and_modify_failures_report_the_failed_operation(self):
        for operation, diagnostic in (("install", "installation"), ("modify", "component reconciliation")):
            with self.subTest(operation=operation):
                self.state["instances"] = [] if operation == "install" else [self.instance(components=[])]
                self.state["calls"] = []
                self.state["results"] = {operation: 23}
                result = self.apply(check=False)
                self.assertIn(diagnostic, result.stdout + result.stderr)
                self.assertIn("23", result.stdout + result.stderr)
                self.assertEqual(self.operations()[-1], operation)

    def test_success_without_required_inventory_is_not_ready(self):
        self.state["ineffective_config"] = True
        result = self.apply(check=False)
        self.assertIn("missing required components", result.stdout + result.stderr)
        self.assertEqual(self.operations(), ["install"])
        self.state["instances"] = [self.instance(components=[])]
        self.state["calls"] = []
        result = self.apply(check=False)
        self.assertIn("missing required components", result.stdout + result.stderr)
        self.assertEqual(self.operations(), ["update", "modify"])

    def test_discovery_failure_is_not_treated_as_absence(self):
        self.state["discovery_exit"] = 19
        result = self.apply(check=False)
        self.assertIn("discovery failed with exit code 19", result.stdout + result.stderr)
        self.assertEqual(self.operations(), [])

    def test_spaces_and_unicode_reach_native_installer_unchanged(self):
        original_config = self.config.read_bytes()
        self.apply()
        arguments = self.state["calls"][0]["argv"]
        self.assertEqual(arguments[arguments.index("--config") + 1], str(self.config))
        self.assertEqual(arguments[arguments.index("--installPath") + 1], str(self.install_path))
        for flag in ("--quiet", "--norestart", "--wait"):
            self.assertIn(flag, arguments)
        self.assertNotIn("--force", arguments)
        self.assertEqual(self.config.read_bytes(), original_config)
        self.assertFalse(Path(self.state["calls"][0]["executable"]).exists())
        self.apply()
        arguments = self.state["calls"][-1]["argv"]
        self.assertEqual(self.operations(), ["install", "update"])
        self.assertEqual(arguments[arguments.index("--installPath") + 1], str(self.install_path))


if __name__ == "__main__":
    unittest.main()
