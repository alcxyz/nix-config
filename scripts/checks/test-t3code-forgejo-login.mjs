// Contract test for T3 Code's Forgejo pull request lookups through tea (#704).
//
// T3 lists tea's stored logins, matches one against the repository remote and
// passes it to tea with --login; the tea wrapper then swaps that login for its
// environment login. This test runs T3's own matching, taken from the packaged
// server bundle, against the logins tea prints for the managed config, and
// checks that T3 still invokes tea the way the wrapper expects. When T3
// renames or rewrites this code the test fails: re-check the tea module
// (modules/home-manager/programs/tea) against the new behaviour and update
// this test.
//
// Usage: node test-t3code-forgejo-login.mjs T3_PACKAGE LOGINS_JSON LOGIN URL SSH_HOST
// T3_PACKAGE is the T3 package or an AI stack bundle that contains it.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const [t3Package, loginsFile, loginName, instanceUrl, sshHost] = process.argv.slice(2);
if (!sshHost) {
  console.error("Usage: test-t3code-forgejo-login.mjs T3_PACKAGE LOGINS_JSON LOGIN URL SSH_HOST");
  process.exit(2);
}

function fail(message) {
  console.error(`FAIL: ${message}`);
  console.error("T3's Forgejo login handling and tea's managed login no longer fit; see modules/home-manager/programs/tea (#704).");
  process.exit(1);
}

const dist = path.join(t3Package, "libexec/t3code/apps/server/dist");
const bundles = fs
  .readdirSync(dist)
  .filter((name) => name.endsWith(".mjs"))
  .map((name) => fs.readFileSync(path.join(dist, name), "utf8"))
  .filter((source) => source.includes("function matchForgejoLogin("));
if (bundles.length !== 1) fail(`expected one server bundle defining matchForgejoLogin, found ${bundles.length}`);
const bundle = bundles[0];

// The shortest text from the single declaration that parses is the whole
// declaration.
function extract(declaration) {
  const start = bundle.indexOf(declaration);
  if (start < 0 || bundle.indexOf(declaration, start + 1) >= 0) fail(`expected exactly one \`${declaration}\``);
  for (let end = start + declaration.length; end < bundle.length; end += 1) {
    if (!"});".includes(bundle[end])) continue;
    const text = bundle.slice(start, end + 1);
    try {
      new vm.Script(text);
      return text;
    } catch {
      // Not complete yet.
    }
  }
  fail(`could not parse \`${declaration}\``);
}
const functionSource = (name) => extract(`function ${name}(`);

// T3 lists stored logins with `tea login list --output json` ...
if (!/args:\s*\[\s*"login",\s*"list",\s*"--output",\s*"json"\s*\]/.test(bundle)) {
  fail("T3 no longer lists tea logins with `tea login list --output json`");
}
// ... and names the matched one with --login, which the wrapper drops.
if (!/"--login",\s*[\w$]+\.login\b/.test(bundle)) fail("T3 no longer passes the matched login to tea with --login");

// Every field T3's login schema requires must be a string in tea's output;
// otherwise T3 decodes the whole list as empty.
const schemaSource = extract("const ForgejoLoginSchema = ");
const schemaFields = [...schemaSource.matchAll(/^\s*(\w+):\s*(optional[\w$]*\()?/gm)].map((match) => ({
  name: match[1],
  optional: Boolean(match[2]),
}));
if (!schemaFields.some((field) => field.name === "ssh_host")) fail("T3's login schema no longer reads ssh_host");

const logins = JSON.parse(fs.readFileSync(loginsFile, "utf8"));
for (const login of logins) {
  for (const field of schemaFields) {
    if (!field.optional && typeof login[field.name] !== "string") {
      fail(`tea's login ${login.name} has no string ${field.name}, which T3's schema requires`);
    }
  }
}
if (!logins.some((login) => login.name === loginName)) fail(`tea lists no ${loginName} login`);

const context = vm.createContext({ URL });
vm.runInContext(
  `${functionSource("parseForgejoRemote")}\n${functionSource("matchForgejoLogin")}\n` +
    "globalThis.parse = parseForgejoRemote; globalThis.match = matchForgejoLogin;",
  context,
);
const { parse, match } = context;
const urlHost = new URL(instanceUrl).host;

// As T3 calls it: SSH remotes also pass the host of the requested PR, if any.
function matched(remoteUrl, requestedHost, candidates = logins) {
  const remote = parse(remoteUrl);
  if (!remote) fail(`T3 cannot parse the remote ${remoteUrl}`);
  return match(candidates, remote, remote.ssh ? requestedHost : undefined, false)?.name;
}

const cases = [
  [`git@${sshHost}:owner/repo.git`, undefined],
  [`git@${sshHost}:owner/repo.git`, urlHost],
  [`ssh://git@${sshHost}/owner/repo.git`, undefined],
  [`${instanceUrl}/owner/repo.git`, undefined],
];
for (const [remoteUrl, requestedHost] of cases) {
  const name = matched(remoteUrl, requestedHost);
  if (name !== loginName) {
    fail(`remote ${remoteUrl} (PR host ${requestedHost ?? "none"}) matched ${name ?? "no login"}, not ${loginName}`);
  }
}
// The matching is not vacuous: another instance's remote finds nothing.
if (matched("git@other.example:owner/repo.git", undefined) !== undefined) {
  fail("a remote on another host matched the managed login");
}

console.log(`T3 Code Forgejo login contract: ok (${cases.length} remotes match ${loginName})`);
