import assert from "node:assert/strict";
import fs from "node:fs";

const workflow = fs.readFileSync(".github/workflows/windows-release.yml", "utf8");
const packageScript = fs.readFileSync("packaging/windows/package.ps1", "utf8");
const readme = fs.readFileSync("README.md", "utf8");

assert.match(packageScript, /portable-no-webview/);
assert.match(packageScript, /-Dwebview=false/);
assert.match(packageScript, /Portable no-WebView build:/);

assert.match(workflow, /portable-no-webview/);
assert.match(workflow, /phantty-windows-portable-no-webview-\$tag\.zip/);
assert.match(workflow, /Upload portable no-WebView artifact/);
assert.match(workflow, /Portable no-WebView:/);

assert.match(readme, /portable-no-webview/);
assert.match(readme, /phantty-windows-portable-no-webview-vX\.Y\.Z\.zip/);
