// Behaviour tests for Model.js. Run with: node test/test_model.js
//
// No framework on purpose: the plugin ships no node_modules, and a plugin the
// user is asked to trust should be readable end to end without one.

const assert = require("assert")
const M = require("../Model.js")

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (error) {
    console.error("FAIL: " + name)
    console.error("      " + error.message)
    process.exitCode = 1
  }
}

const NOW = 1_800_000_000

const ENTRIES = [
  { id: "google-chrome-stable:Default", label: "🌐  Chrome — Acme", browser: "Chrome", family: "chromium", bin: "google-chrome-stable", profile: "Default", manage: false },
  { id: "google-chrome-stable:Profile 17", label: "🌐  Chrome — Design Studio", browser: "Chrome", family: "chromium", bin: "google-chrome-stable", profile: "Profile 17", manage: false },
  { id: "chromium:Profile 19", label: "🧪  Chromium — Work", browser: "Chromium", family: "chromium", bin: "chromium", profile: "Profile 19", manage: false },
  { id: "firefox:dev", label: "🦊  Firefox — dev", browser: "Firefox", family: "firefox", bin: "firefox", profile: "dev", manage: false },
  { id: "google-chrome-stable:__manage__", label: "➕  Chrome — manage profiles", browser: "Chrome", family: "chromium", bin: "google-chrome-stable", profile: "", manage: true }
]

// ------------------------------------------------------------------ hostOf

test("hostOf strips scheme, path, port and userinfo", () => {
  assert.equal(M.hostOf("https://github.com/anthropics/claude"), "github.com")
  assert.equal(M.hostOf("http://user:pw@Portal.Example.COM:8443/x"), "portal.example.com")
  assert.equal(M.hostOf("example.com/path"), "example.com")
})

test("hostOf keeps IPv6 literals intact", () => {
  assert.equal(M.hostOf("http://[::1]:8080/admin"), "[::1]")
})

test("hostOf returns empty for things that are not URLs", () => {
  assert.equal(M.hostOf(""), "")
  assert.equal(M.hostOf("   "), "")
})

// ------------------------------------------------------------------- rules

test("a bare domain covers its subdomains", () => {
  assert.ok(M.ruleMatches("example.com", "example.com"))
  assert.ok(M.ruleMatches("example.com", "portal.example.com"))
})

test("a bare domain does not match a lookalike suffix", () => {
  assert.ok(!M.ruleMatches("example.com", "notexample.com"))
  assert.ok(!M.ruleMatches("example.com", "example.com.evil.net"))
})

test("*.domain covers subdomains but not the apex", () => {
  assert.ok(M.ruleMatches("*.example.com", "portal.example.com"))
  assert.ok(!M.ruleMatches("*.example.com", "example.com"))
})

test("the most specific rule wins regardless of order", () => {
  const rules = [
    { pattern: "example.com", entryId: "a" },
    { pattern: "docs.example.com", entryId: "b" }
  ]
  assert.equal(M.matchRule(rules, "docs.example.com").entryId, "b")
  assert.equal(M.matchRule(rules, "www.example.com").entryId, "a")
  assert.equal(M.matchRule(rules, "other.org"), null)
})

test("upsertRule replaces rather than duplicates a pattern", () => {
  let rules = M.upsertRule([], "example.com", "a", false)
  rules = M.upsertRule(rules, "example.com", "b", true)
  assert.equal(rules.length, 1)
  assert.equal(rules[0].entryId, "b")
  assert.equal(rules[0].learned, true)
})

test("parseConfig drops malformed rules instead of throwing", () => {
  const config = M.parseConfig('{"rules":[{"pattern":"a.com","entryId":"x"},{"pattern":""},null,7]}')
  assert.equal(config.rules.length, 1)
  assert.equal(M.parseConfig("not json").rules.length, 0)
})

// --------------------------------------------------------------- frecency

test("a recent choice outranks an old one with the same count", () => {
  const fresh = M.decayedScore({ count: 3, last: NOW }, NOW)
  const stale = M.decayedScore({ count: 3, last: NOW - 60 * 86400 }, NOW)
  assert.ok(fresh > stale * 4, `expected decay, got ${fresh} vs ${stale}`)
})

test("one host-specific hit beats heavy general use elsewhere", () => {
  let state = M.parseState("")
  // The personal profile is used constantly, but never for this host.
  for (let i = 0; i < 50; i++) state = M.recordChoice(state, "chromium:Profile 19", "", NOW)
  // The work profile was used for this host exactly once.
  state = M.recordChoice(state, "google-chrome-stable:Default", "github.com", NOW)

  const work = M.scoreFor(state, "google-chrome-stable:Default", "github.com", NOW)
  const personal = M.scoreFor(state, "chromium:Profile 19", "github.com", NOW)
  assert.ok(work > personal, `host signal must dominate: ${work} vs ${personal}`)
})

test("recordChoice does not mutate the state it was given", () => {
  const before = M.parseState("")
  const after = M.recordChoice(before, "a", "example.com", NOW)
  assert.equal(Object.keys(before.entries).length, 0)
  assert.equal(Object.keys(after.entries).length, 1)
  assert.equal(M.domainHits(after, "example.com", "a"), 1)
})

// ------------------------------------------------------------- rule offers

test("a permanent rule is offered only once the habit repeats", () => {
  const config = M.parseConfig("")
  let state = M.parseState("")
  const entry = ENTRIES[0]

  state = M.recordChoice(state, entry.id, "github.com", NOW)
  assert.ok(!M.shouldOfferRule(state, config, "github.com", entry, 3))
  state = M.recordChoice(state, entry.id, "github.com", NOW)
  state = M.recordChoice(state, entry.id, "github.com", NOW)
  assert.ok(M.shouldOfferRule(state, config, "github.com", entry, 3))
})

test("no offer for a host that already has a rule, or for manage rows", () => {
  let state = M.parseState("")
  for (let i = 0; i < 5; i++) state = M.recordChoice(state, ENTRIES[0].id, "github.com", NOW)

  const withRule = M.parseConfig(JSON.stringify({
    rules: [{ pattern: "github.com", entryId: ENTRIES[0].id }]
  }))
  assert.ok(!M.shouldOfferRule(state, withRule, "github.com", ENTRIES[0], 3))

  let manageState = M.parseState("")
  for (let i = 0; i < 5; i++) manageState = M.recordChoice(manageState, ENTRIES[4].id, "github.com", NOW)
  assert.ok(!M.shouldOfferRule(manageState, M.parseConfig(""), "github.com", ENTRIES[4], 3))
})

// ------------------------------------------------------------------ search

test("an fzf-style subsequence finds the profile", () => {
  assert.ok(M.fuzzyScore("🌐  Chrome — Design Studio", "chdes") >= 0)
  assert.ok(M.fuzzyScore("🌐  Chrome — Design Studio", "zzz") < 0)
})

test("a word-start match outranks a scattered one", () => {
  const wordStart = M.fuzzyScore("🌐  Chrome — Design", "des")
  const scattered = M.fuzzyScore("🧪  Chromium — Faded Rose", "des")
  assert.ok(wordStart > scattered, `${wordStart} should beat ${scattered}`)
})

// ----------------------------------------------------------------- ranking

test("a rule target outranks even the pinned bands", () => {
  const config = M.parseConfig(JSON.stringify({
    rules: [{ pattern: "example.com", entryId: "chromium:Profile 19" }]
  }))
  const ranked = M.rankEntries(ENTRIES, M.parseState(""), config, "example.com", "", NOW)
  assert.equal(ranked[0].id, "chromium:Profile 19")
})

test("manage rows lead by default and can be sent back down", () => {
  const ranked = M.rankEntries(ENTRIES, M.parseState(""), M.parseConfig(""), "", "", NOW)
  assert.equal(ranked[0].manage, true, "manage should lead by default")

  const off = M.parseConfig(JSON.stringify({ settings: { manageFirst: false } }))
  const trailing = M.rankEntries(ENTRIES, M.parseState(""), off, "", "", NOW)
  assert.equal(trailing[trailing.length - 1].manage, true)
  assert.equal(trailing[0].manage, undefined === trailing[0].manage ? undefined : false)
})

test("a typed query outranks the manage pin", () => {
  // "chrome" matches the manage row exactly as well as every Chrome profile.
  // The pin must not apply, and the tie must not go to housekeeping either.
  const ranked = M.rankEntries(ENTRIES, M.parseState(""), M.parseConfig(""), "", "chrome", NOW)
  assert.ok(ranked.length > 1, "the query should match several rows")
  assert.notEqual(ranked[0].manage, true, "a destination must lead, not the manage row")
  assert.equal(ranked[ranked.length - 1].manage, true)
})

test("a query filters the list without losing the match", () => {
  const ranked = M.rankEntries(ENTRIES, M.parseState(""), M.parseConfig(""), "", "firefox", NOW)
  assert.equal(ranked.length, 1)
  assert.equal(ranked[0].id, "firefox:dev")
})

// --------------------------------------------------------------- launching

test("each family gets its own profile flag", () => {
  assert.deepEqual(
    M.launchArgs(ENTRIES[0], ["https://x.test"], []),
    ["--profile-directory=Default", "https://x.test"]
  )
  assert.deepEqual(
    M.launchArgs(ENTRIES[3], ["https://x.test"], []),
    ["-P", "dev", "https://x.test"]
  )
})

test("--incognito becomes --private-window for the Firefox family", () => {
  assert.deepEqual(
    M.launchArgs(ENTRIES[3], ["https://x.test"], ["--incognito"]),
    ["-P", "dev", "--private-window", "https://x.test"]
  )
  assert.deepEqual(
    M.launchArgs(ENTRIES[0], ["https://x.test"], ["--incognito"]),
    ["--profile-directory=Default", "--incognito", "https://x.test"]
  )
})

test("a manage row opens the profile screen and ignores the URL", () => {
  const args = M.launchArgs(ENTRIES[4], ["https://x.test"], [])
  assert.deepEqual(args, ["chrome://profile-picker"])
})

// --------------------------------------------------------------- migration

test("the v2 bash rules file imports by label substring", () => {
  const legacy = [
    "# a comment",
    "",
    "example.com        Design Studio",
    "work.example.com   Work",
    "orphan.test        NoSuchProfile"
  ].join("\n")

  const rules = M.migrateLegacyRules(legacy, ENTRIES)
  assert.equal(rules.length, 2)
  assert.equal(rules[0].entryId, "google-chrome-stable:Profile 17")
  assert.equal(rules[1].entryId, "chromium:Profile 19")
})

// ----------------------------------------------------- generic entries

test("a browser with no separate profiles leads the list", () => {
  const entries = [
    { id: "google-chrome-stable:Default", label: "🌐  Chrome — Aaa", family: "chromium", bin: "google-chrome-stable", profile: "Default", manage: false, generic: false },
    { id: "firefox:", label: "🦊  Firefox", family: "firefox", bin: "firefox", profile: "", manage: false, generic: true },
    { id: "google-chrome-stable:__manage__", label: "➕  Chrome — manage profiles", family: "chromium", bin: "google-chrome-stable", profile: "", manage: true, generic: false }
  ]
  const ranked = M.rankEntries(entries, M.parseState(""), M.parseConfig(""), "", "", NOW)
  // Manage rows hold the first band, so "leads" means first real destination.
  const destinations = ranked.filter(e => !e.manage)
  assert.equal(destinations[0].id, "firefox:", "generic entry should lead the destinations")
  assert.equal(ranked[0].manage, true)
})

test("genericFirst false puts it back in alphabetical order", () => {
  const entries = [
    { id: "google-chrome-stable:Default", label: "🌐  Chrome — Aaa", family: "chromium", bin: "google-chrome-stable", profile: "Default", manage: false, generic: false },
    { id: "firefox:", label: "🦊  Firefox", family: "firefox", bin: "firefox", profile: "", manage: false, generic: true }
  ]
  const config = M.parseConfig(JSON.stringify({ settings: { genericFirst: false } }))
  const ranked = M.rankEntries(entries, M.parseState(""), config, "", "", NOW)
  assert.equal(ranked[0].id, "google-chrome-stable:Default")
})

test("a typed query outranks the generic pin", () => {
  const entries = [
    { id: "chromium:Profile 19", label: "🧪  Chromium — Work", family: "chromium", bin: "chromium", profile: "Profile 19", manage: false, generic: false },
    { id: "firefox:", label: "🦊  Firefox", family: "firefox", bin: "firefox", profile: "", manage: false, generic: true }
  ]
  const ranked = M.rankEntries(entries, M.parseState(""), M.parseConfig(""), "", "work", NOW)
  assert.equal(ranked[0].id, "chromium:Profile 19", "search relevance must win while typing")
})

console.log(`${passed} passed`)
