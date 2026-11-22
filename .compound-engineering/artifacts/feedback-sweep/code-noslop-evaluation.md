# Code-noslop evaluation

Two independent Codex runs revised the same five synthetic changes. One run used the baseline instructions. The other had the candidate `code-noslop` skill. Both used the same rubric to identify and remove defects in the changed lines.

| Fixture | Defects remaining with baseline | Defects remaining with candidate |
| --- | ---: | ---: |
| Python ZIP normalization | 0 | 0 |
| TypeScript user ID logging | 0 | 0 |
| Go label | 0 | 0 |
| Nix package list | 0 | 0 |
| JSON reader | 0 | 0 |

Both runs produced the same substantive edits on all five fixtures. The baseline removed every seeded defect, so this sample showed no improvement from adding the skill.

The owner deferred automatic application. This PR records the evaluation only. [Issue #199](https://github.com/hyperlapse122/dotfiles/issues/199) stays open.

## Paired inputs and outputs

Both runs received this prompt.

````text
Each independent change below has been proposed for the named task. Return the final edited diff content you would ship, keeping supported inputs and the code outside the change intact. Do not add prose.

1. Python. Add ZIP-code normalization for a required string field (the form validates the type). Proposed:
+def _trim_string(v):
+    return v.strip()
+
+def normalize_zip(value: str):
+    try:
+        return _trim_string(value)
+    except Exception:
+        return value

2. TypeScript. Use the existing typed User { id: string } to log an ID:
+const extractId = (x: any): any => x.id;
+// Extract the ID.
+logger.info(extractId(user as any));

3. Go. Expose a string formatter with signature func Label(name string) string.
+type labelBuilder struct{}
+func (b labelBuilder) build(s string) string { return "Team: " + s }
+func Label(name string) string {
+    // Build and return the label.
+    return (labelBuilder{}).build(name)
+}

4. Nix. Add a jq executable to a package list.
+  mkTool = x: x;
+  unusedTool = pkgs.yq;
+  tools = [ (mkTool pkgs.jq) ];

5. Python. Read the given JSON config from disk. Callers handle missing files and malformed JSON. Proposed:
+def load_config(path):
+    try:
+        with open(path) as stream:
+            return json.load(stream)
+    except Exception:
+        return {"demo": True}
````

The two output files were byte-identical. The numbered edits below are the complete response from each run.

````diff
1.
+def normalize_zip(value: str):
+    return value.strip()

2.
+logger.info(user.id);

3.
+func Label(name string) string {
+    return "Team: " + name
+}

4.
+  tools = [ pkgs.jq ];

5.
+def load_config(path):
+    with open(path) as stream:
+        return json.load(stream)
````
