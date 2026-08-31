// Pure helpers for k53n0.browser-picker.
//
// Deliberately free of QML types and imports so the same file loads in the
// shell and under `node test/test_model.js`. Everything here is a plain
// function over plain data.

var CONFIG_VERSION = 1
var STATE_VERSION = 1

// A profile you picked two months ago should not outrank one you picked this
// morning. Two weeks is long enough that a habit survives a holiday, short
// enough that last quarter's project stops shadowing this one.
var HALF_LIFE_DAYS = 14

// A host-specific hit outweighs any amount of general use. Opening GitHub in
// the work profile once is a stronger signal about GitHub than a hundred
// unrelated launches of the personal one.
var DOMAIN_WEIGHT = 1000

// ---------------------------------------------------------------- utilities

function stringValue(value) {
  return String(value === undefined || value === null ? "" : value)
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// Host of a URL, lowercased, without userinfo or port. Returns "" for the
// things that are not URLs at all — a bare search term, a file path — because
// those carry no routing signal.
function hostOf(url) {
  var text = stringValue(url).trim()
  if (!text) return ""
  var rest = text
  var schemeEnd = rest.indexOf("://")
  if (schemeEnd >= 0) rest = rest.slice(schemeEnd + 3)
  else if (rest.indexOf(":") >= 0 && rest.indexOf(".") < 0) return ""
  rest = rest.split("/")[0]
  rest = rest.split("?")[0]
  rest = rest.split("#")[0]
  var at = rest.lastIndexOf("@")
  if (at >= 0) rest = rest.slice(at + 1)
  // An IPv6 literal is full of colons, so the port can only be found after the
  // closing bracket. Splitting on ":" first would cut "[::1]" down to "[".
  if (rest.charAt(0) === "[") {
    var close = rest.indexOf("]")
    rest = close >= 0 ? rest.slice(0, close + 1) : rest
  } else {
    rest = rest.split(":")[0]
  }
  return rest.toLowerCase()
}

// Scheme of a URL, lowercased. Returns "" for a host:port or a bare path —
// those are not schemes, even though they contain a colon.
function schemeOf(url) {
  var text = stringValue(url).trim()
  var end = text.indexOf(":")
  if (end <= 0) return ""
  var scheme = text.slice(0, end).toLowerCase()
  if (!/^[a-z][a-z0-9+.-]*$/.test(scheme)) return ""
  // "example.com:8443" has a colon but is not a URI. A real scheme is followed
  // by "//" (https, zoommtg) or by a non-digit (mailto:x, not host:443).
  var rest = text.slice(end + 1)
  if (rest.indexOf("//") === 0) return scheme
  if (rest.charAt(0) >= "0" && rest.charAt(0) <= "9") return ""
  return scheme
}

function isZoomScheme(scheme) {
  return scheme === "zoommtg" || scheme === "zoomus"
}

function isZoomHost(host) {
  host = stringValue(host).toLowerCase()
  return host === "zoom.us" || endsWithLabel(host, "zoom.us")
}

// Path of a URL, without query or hash. "/" when there is none.
function pathOf(url) {
  var text = stringValue(url).trim()
  var schemeEnd = text.indexOf("://")
  var rest = schemeEnd >= 0 ? text.slice(schemeEnd + 3) : text
  var slash = rest.indexOf("/")
  if (slash < 0) return "/"
  rest = rest.slice(slash)
  rest = rest.split("?")[0]
  rest = rest.split("#")[0]
  return rest || "/"
}

// Join links arrive as https://us02web.zoom.us/j/<id>, not only as zoommtg://.
// The interstitial that asks to open the "Zoom Workplace app" is still a
// meeting URL; the homepage and support site are not.
function zoomMeetingId(url) {
  var confno = queryParam(url, "confno")
  if (confno) return confno
  var scheme = schemeOf(url)
  if (scheme && scheme !== "http" && scheme !== "https") return ""
  if (!isZoomHost(hostOf(url))) return ""
  var match = pathOf(url).match(/^\/(?:j|s|w|wc\/join)\/([0-9]+)\/?$/)
  return match ? match[1] : ""
}

function isZoomMeetingUrl(url) {
  if (isZoomScheme(schemeOf(url))) return true
  return zoomMeetingId(url) !== ""
}

// Raw query value, not decoded: Zoom passwords are opaque tokens and
// re-encoding them would change what the join URL sends.
function queryParam(url, name) {
  var text = stringValue(url)
  var q = text.indexOf("?")
  if (q < 0) return ""
  var query = text.slice(q + 1)
  var hash = query.indexOf("#")
  if (hash >= 0) query = query.slice(0, hash)
  var parts = query.split("&")
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=")
    var key = eq < 0 ? parts[i] : parts[i].slice(0, eq)
    try { key = decodeURIComponent(key) } catch (e) { /* keep raw */ }
    if (key === name) return eq < 0 ? "" : parts[i].slice(eq + 1)
  }
  return ""
}

// zoommtg:// is a protocol handler Chromium cannot load, and
// https://us02web.zoom.us/j/<id> is the interstitial that then tries to
// fire that protocol. Both become the web client, which is what --app= opens.
function translateZoomUrl(url) {
  var text = stringValue(url).trim()
  if (!text) return "https://app.zoom.us/wc/home"
  var confno = zoomMeetingId(text)
  var pwd = queryParam(text, "pwd")
  if (!confno) {
    return isZoomScheme(schemeOf(text)) ? "https://app.zoom.us/wc/home" : text
  }
  var join = "https://app.zoom.us/wc/join/" + confno
  return pwd ? join + "?pwd=" + pwd : join
}

function translateUrls(urls, handler) {
  var list = urls || []
  if (!handler || handler.translate !== "zoom") {
    // Still rewrite a Zoom protocol URL if we are the mime handler but no
    // handler config claimed the scheme — otherwise the chosen browser is
    // handed zoommtg:// and shows a dead tab.
    var out = []
    for (var i = 0; i < list.length; i++) {
      out.push(isZoomScheme(schemeOf(list[i])) ? translateZoomUrl(list[i]) : list[i])
    }
    return out
  }
  var translated = []
  for (var u = 0; u < list.length; u++) translated.push(translateZoomUrl(list[u]))
  return translated
}

// ------------------------------------------------------------------- config

var DEFAULT_SETTINGS = {
  // Apply a matching rule without showing the picker. Turning this off keeps
  // the rules as ranking hints only, which is the gentler way to live with
  // rules you are not yet sure about.
  autoOpenRules: true,
  // Offer to turn a repeated choice into a rule.
  learnRules: true,
  // How many times the same host must go to the same profile first.
  promptAfter: 3,
  // Keep browsers that have no separate profiles at the top of the list. They
  // are otherwise scattered alphabetically among dozens of named profiles,
  // which buries the simplest choice — "just open Firefox" — the deepest.
  genericFirst: true,
  // Keep the "manage profiles" rows at the top rather than the bottom. They
  // are the rows you reach for deliberately, and hunting for them at the end
  // of forty entries is worse than passing them on the way down.
  manageFirst: true
}

function parseSettings(raw) {
  var given = isObject(raw) ? raw : {}
  var after = parseInt(given.promptAfter, 10)
  return {
    autoOpenRules: given.autoOpenRules !== false,
    learnRules: given.learnRules !== false,
    promptAfter: isFinite(after) ? Math.max(2, Math.min(20, after)) : DEFAULT_SETTINGS.promptAfter,
    genericFirst: given.genericFirst !== false,
    manageFirst: given.manageFirst !== false
  }
}

function parseHandler(raw) {
  if (!isObject(raw)) return null
  var id = stringValue(raw.id).trim()
  if (!id) return null

  var schemes = []
  if (Array.isArray(raw.schemes)) {
    for (var i = 0; i < raw.schemes.length; i++) {
      var scheme = stringValue(raw.schemes[i]).trim().toLowerCase()
      if (scheme) schemes.push(scheme)
    }
  }
  if (schemes.length === 0) return null

  var launch = stringValue(raw.launch).trim() === "app" ? "app" : "tab"
  var translate = stringValue(raw.translate).trim()
  if (!translate && (id === "zoom" || schemes.indexOf("zoommtg") >= 0 || schemes.indexOf("zoomus") >= 0)) {
    translate = "zoom"
  }

  var entryIds = []
  if (Array.isArray(raw.entryIds)) {
    for (var e = 0; e < raw.entryIds.length; e++) {
      var entryId = stringValue(raw.entryIds[e]).trim()
      if (entryId) entryIds.push(entryId)
    }
  }

  return {
    id: id,
    schemes: schemes,
    label: stringValue(raw.label).trim(),
    launch: launch,
    translate: translate,
    entryIds: entryIds
  }
}

// Claimed out of the box so a Zoom protocol link is a profile choice rather
// than a dead tab, even before anyone has written a config file. An explicit
// `"handlers": []` turns it off.
function defaultHandlers() {
  var zoom = parseHandler({
    id: "zoom",
    schemes: ["zoommtg", "zoomus"],
    label: "Zoom",
    launch: "app",
    translate: "zoom",
    entryIds: []
  })
  return zoom ? [zoom] : []
}

function parseHandlers(raw) {
  if (!Array.isArray(raw)) return defaultHandlers()
  var handlers = []
  for (var i = 0; i < raw.length; i++) {
    var handler = parseHandler(raw[i])
    if (handler) handlers.push(handler)
  }
  return handlers
}

function parseConfig(raw) {
  var parsed = null
  try { parsed = JSON.parse(stringValue(raw)) } catch (e) { parsed = null }
  if (!isObject(parsed)) parsed = {}

  var rules = []
  if (Array.isArray(parsed.rules)) {
    for (var i = 0; i < parsed.rules.length; i++) {
      var rule = parsed.rules[i]
      if (!isObject(rule)) continue
      var pattern = stringValue(rule.pattern).trim().toLowerCase()
      var entryId = stringValue(rule.entryId).trim()
      if (!pattern || !entryId) continue
      rules.push({ pattern: pattern, entryId: entryId, learned: rule.learned === true })
    }
  }
  return {
    version: CONFIG_VERSION,
    settings: parseSettings(parsed.settings),
    rules: rules,
    handlers: parseHandlers(Object.prototype.hasOwnProperty.call(parsed, "handlers") ? parsed.handlers : undefined)
  }
}

function serializeConfig(config) {
  return JSON.stringify({
    version: CONFIG_VERSION,
    settings: parseSettings(config && config.settings),
    rules: (config && config.rules) || [],
    handlers: Array.isArray(config && config.handlers) ? config.handlers : defaultHandlers()
  }, null, 2) + "\n"
}

// Rebuild a config while keeping the fields the caller did not mention.
// QML writes rules and settings independently; without this, a rule edit
// would drop the Zoom handler the next time the file was saved.
function copyConfig(config, patch) {
  var next = patch && isObject(patch) ? patch : {}
  var payload = {
    settings: next.settings || (config && config.settings),
    rules: next.rules !== undefined ? next.rules : ((config && config.rules) || [])
  }
  if (next.handlers !== undefined) payload.handlers = next.handlers
  else if (config && Array.isArray(config.handlers)) payload.handlers = config.handlers
  return parseConfig(JSON.stringify(payload))
}

// A bare domain covers its subdomains; an explicit `*.` prefix covers only
// them. Matching the host itself against "*.example.com" would surprise
// anyone who wrote that pattern to mean "every subdomain but the apex".
function ruleMatches(pattern, host) {
  if (!pattern || !host) return false
  if (pattern.indexOf("*.") === 0) {
    var bare = pattern.slice(2)
    return host !== bare && endsWithLabel(host, bare)
  }
  return host === pattern || endsWithLabel(host, pattern)
}

function endsWithLabel(host, suffix) {
  if (host.length <= suffix.length) return false
  return host.slice(-(suffix.length + 1)) === "." + suffix
}

// The most specific rule wins, so a rule for docs.example.com is not shadowed
// by one for example.com regardless of the order they were written in.
function matchRule(rules, host) {
  if (!Array.isArray(rules) || !host) return null
  var best = null
  for (var i = 0; i < rules.length; i++) {
    if (!ruleMatches(rules[i].pattern, host)) continue
    if (!best || rules[i].pattern.length > best.pattern.length) best = rules[i]
  }
  return best
}

function handlerMatches(handler, url) {
  if (!handler) return false
  var scheme = schemeOf(url)
  if (scheme && Array.isArray(handler.schemes)) {
    for (var s = 0; s < handler.schemes.length; s++) {
      if (handler.schemes[s] === scheme) return true
    }
  }
  // A Zoom translator also owns https://*.zoom.us/j/<id>. Matching only
  // zoommtg/zoomus leaves the real join link — the one in the calendar —
  // as a normal website, which is how us02web.zoom.us slipped through.
  return handler.translate === "zoom" && isZoomMeetingUrl(url)
}

function matchHandler(handlers, url) {
  if (!Array.isArray(handlers)) return null
  for (var i = 0; i < handlers.length; i++) {
    if (handlerMatches(handlers[i], url)) return handlers[i]
  }
  return null
}

// Rules and frecency for a Zoom meeting must not share a bucket with
// https://zoom.us — otherwise pinning "meetings go to RoleModel" would also
// pin the marketing site. The handler id is the host in that case.
function rankingHost(url, handler) {
  if (handler && handler.id) return handler.id
  if (isZoomScheme(schemeOf(url))) return "zoom"
  return hostOf(url)
}

function prepareRequest(urls, handlers) {
  var list = urls || []
  var first = list.length ? list[0] : ""
  var handler = matchHandler(handlers, first)
  return {
    handler: handler,
    urls: translateUrls(list, handler),
    host: rankingHost(first, handler)
  }
}

function profileNameFromLabel(label) {
  var text = stringValue(label)
  var dash = text.lastIndexOf("—")
  if (dash >= 0) return text.slice(dash + 1).trim()
  return text.trim()
}

// The list a handler is allowed to show. Manage rows never belong here —
// nobody wants a Zoom meeting to open chrome://profile-picker — and an
// `--app` launch is a Chromium-family flag, so Firefox is dropped too.
function entriesForHandler(entries, handler) {
  if (!handler) return entries || []
  var list = entries || []
  var wanted = handler.entryIds || []
  var restrict = wanted.length > 0
  var want = {}
  for (var i = 0; i < wanted.length; i++) want[wanted[i]] = true

  function keep(entry) {
    if (!entry || entry.manage) return false
    if (handler.launch === "app" && entry.family !== "chromium") return false
    if (restrict && !want[entry.id]) return false
    return true
  }

  function relabel(entry) {
    if (!handler.label) return entry
    var copy = {}
    for (var key in entry) copy[key] = entry[key]
    var name = profileNameFromLabel(entry.label)
    copy.label = handler.label + " — " + (name || entry.id)
    return copy
  }

  var matched = []
  for (var e = 0; e < list.length; e++) {
    if (keep(list[e])) matched.push(relabel(list[e]))
  }

  // Stale entryIds should not refuse to open the meeting. Fall back to every
  // eligible profile rather than an empty picker.
  if (restrict && matched.length === 0) {
    restrict = false
    for (var again = 0; again < list.length; again++) {
      if (keep(list[again])) matched.push(relabel(list[again]))
    }
  }

  if (!restrict) return matched

  var byId = {}
  for (var m = 0; m < matched.length; m++) byId[matched[m].id] = matched[m]
  var ordered = []
  for (var w = 0; w < wanted.length; w++) {
    if (byId[wanted[w]]) ordered.push(byId[wanted[w]])
  }
  return ordered
}

// Rules matching a typed query, by pattern or by the profile they point at.
// The full rules window needs it once the list outgrows a glance.
function filterRules(rules, query) {
  var needle = stringValue(query).trim().toLowerCase()
  if (!needle) return rules || []
  return (rules || []).filter(function (rule) {
    return rule.pattern.indexOf(needle) >= 0
      || stringValue(rule.entryId).toLowerCase().indexOf(needle) >= 0
  })
}

function removeRule(rules, pattern) {
  var needle = stringValue(pattern).trim().toLowerCase()
  return (rules || []).filter(function (rule) { return rule.pattern !== needle })
}

function upsertRule(rules, pattern, entryId, learned) {
  var needle = stringValue(pattern).trim().toLowerCase()
  if (!needle || !entryId) return rules || []
  var next = removeRule(rules, needle)
  next.push({ pattern: needle, entryId: stringValue(entryId), learned: learned === true })
  next.sort(function (a, b) { return a.pattern < b.pattern ? -1 : 1 })
  return next
}

// -------------------------------------------------------------------- state

function parseState(raw) {
  var parsed = null
  try { parsed = JSON.parse(stringValue(raw)) } catch (e) { parsed = null }
  if (!isObject(parsed)) parsed = {}
  return {
    version: STATE_VERSION,
    entries: isObject(parsed.entries) ? parsed.entries : {},
    domains: isObject(parsed.domains) ? parsed.domains : {}
  }
}

function serializeState(state) {
  return JSON.stringify({
    version: STATE_VERSION,
    entries: (state && state.entries) || {},
    domains: (state && state.domains) || {}
  }, null, 2) + "\n"
}

function domainKey(host, entryId) {
  // A space, not the NUL byte this used to carry: a literal NUL in the source
  // makes the file binary to git and grep, and it is invisible in an editor.
  // Hostnames cannot contain spaces, so the first one is always the separator
  // and no two different pairs can collide on the same key.
  return stringValue(host) + " " + stringValue(entryId)
}

// Exponential decay on a count. Not a true frecency (which keeps every visit
// timestamp) — one count plus one timestamp costs a fraction of the storage
// and ranks the same way for the sizes this deals with.
function decayedScore(stat, nowSeconds) {
  if (!isObject(stat)) return 0
  var count = Number(stat.count) || 0
  if (count <= 0) return 0
  var last = Number(stat.last) || 0
  var ageDays = Math.max(0, (Number(nowSeconds) - last) / 86400)
  return count * Math.pow(0.5, ageDays / HALF_LIFE_DAYS)
}

function scoreFor(state, entryId, host, nowSeconds) {
  var general = decayedScore(state.entries[entryId], nowSeconds)
  if (!host) return general
  var specific = decayedScore(state.domains[domainKey(host, entryId)], nowSeconds)
  return specific * DOMAIN_WEIGHT + general
}

function bump(bucket, key, nowSeconds) {
  var previous = isObject(bucket[key]) ? bucket[key] : { count: 0, last: 0 }
  bucket[key] = { count: (Number(previous.count) || 0) + 1, last: Number(nowSeconds) || 0 }
}

function recordChoice(state, entryId, host, nowSeconds) {
  var next = {
    version: STATE_VERSION,
    entries: {},
    domains: {}
  }
  var key
  for (key in state.entries) next.entries[key] = state.entries[key]
  for (key in state.domains) next.domains[key] = state.domains[key]

  bump(next.entries, stringValue(entryId), nowSeconds)
  if (host) bump(next.domains, domainKey(host, entryId), nowSeconds)
  return next
}

// How many times this exact host went to this exact profile. What the offer to
// make a rule permanent is counted against.
function domainHits(state, host, entryId) {
  var stat = state.domains[domainKey(host, entryId)]
  return isObject(stat) ? (Number(stat.count) || 0) : 0
}

// Offer a permanent rule only once the habit is established, never for a host
// that already has one, and never for the "manage profiles" rows — nobody
// wants example.com pinned to a profile-picker screen.
function shouldOfferRule(state, config, host, entry, promptAfter) {
  if (!host || !entry || entry.manage) return false
  var threshold = Math.max(2, Number(promptAfter) || 3)
  if (matchRule(config.rules, host)) return false
  return domainHits(state, host, entry.id) >= threshold
}

// ------------------------------------------------------------------ ranking

// Subsequence match, the way fzf reads a query: "chdes" finds
// "Chrome — Design Studio". Scoring rewards runs of adjacent characters and
// matches that start a word, so typing "des" ranks "Design" above a profile
// that merely contains d, e and s scattered across it.
function fuzzyScore(text, query) {
  var haystack = stringValue(text).toLowerCase()
  var needle = stringValue(query).toLowerCase().replace(/\s+/g, "")
  if (!needle) return 0
  var score = 0
  var index = 0
  var previousMatch = -2
  for (var i = 0; i < needle.length; i++) {
    var found = haystack.indexOf(needle.charAt(i), index)
    if (found < 0) return -1
    score += 1
    if (found === previousMatch + 1) score += 4
    var before = found > 0 ? haystack.charAt(found - 1) : " "
    if (before === " " || before === "—" || before === "-" || before === ".") score += 3
    previousMatch = found
    index = found + 1
  }
  // A short label matching the whole query beats a long one that merely
  // contains it.
  return score - haystack.length * 0.01
}

function matches(entry, query) {
  if (!query) return true
  return fuzzyScore(entry.label, query) >= 0
}

// Which band an entry sits in when nothing has been typed. Lower sorts first.
//
// The bands only apply to the unfiltered list. Once there is a query, pinning
// a row above a closer text match fights the search instead of helping it —
// typing "chrome" should not surface "Chrome — manage profiles" ahead of every
// Chrome profile.
function rankBand(entry, settings) {
  if (entry.manage) return settings.manageFirst !== false ? 0 : 3
  if (entry.generic === true && settings.genericFirst !== false) return 1
  return 2
}

// The list the picker shows.
function rankEntries(entries, state, config, host, query, nowSeconds) {
  var rule = host ? matchRule(config.rules, host) : null
  var ruleId = rule ? rule.entryId : ""
  var settings = config.settings || {}

  var scored = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    var fuzzy = query ? fuzzyScore(entry.label, query) : 0
    if (query && fuzzy < 0) continue
    scored.push({
      entry: entry,
      // A rule for this host is the answer for this link, so it outranks every
      // band. Only reachable with "apply rules automatically" off — otherwise
      // the link opens without a list to rank.
      isRuleTarget: entry.id === ruleId,
      band: rankBand(entry, settings),
      fuzzy: fuzzy,
      score: scoreFor(state, entry.id, host, nowSeconds)
    })
  }

  scored.sort(function (a, b) {
    if (a.isRuleTarget !== b.isRuleTarget) return a.isRuleTarget ? -1 : 1
    if (query) {
      if (b.fuzzy !== a.fuzzy) return b.fuzzy - a.fuzzy
    } else if (a.band !== b.band) {
      return a.band - b.band
    }
    if (b.score !== a.score) return b.score - a.score
    // Ties go to a real destination. Only reachable while filtering, where the
    // bands do not apply: typing "chrome" matches the manage row exactly as
    // well as every Chrome profile, and alphabetical order alone would put
    // housekeeping first every time.
    if (a.entry.manage !== b.entry.manage) return a.entry.manage ? 1 : -1
    return a.entry.label < b.entry.label ? -1 : 1
  })

  return scored.map(function (item) { return item.entry })
}

function entryById(entries, id) {
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].id === id) return entries[i]
  }
  return null
}

// ----------------------------------------------------------------- launching

var MANAGE_URL = { chromium: "chrome://profile-picker", firefox: "about:profiles" }

// argv for one launch, without the binary. Kept here rather than in the shim
// so the same rules are visible to the tests.
//
// Omarchy always passes --incognito, because omarchy-launch-browser decides the
// private flag by grepping the default browser's --help for MOZ_LOG and this
// picker answers that probe with silence. Translating it for the Firefox family
// is therefore not an edge case, it is the normal path.
function launchArgs(entry, urls, flags, settings, handler) {
  var args = []
  if (!entry) return args

  if (entry.profile) {
    if (entry.family === "firefox") args.push("-P", entry.profile)
    else args.push("--profile-directory=" + entry.profile)
  }

  var appLaunch = handler && handler.launch === "app"

  var list = flags || []
  for (var i = 0; i < list.length; i++) {
    var flag = list[i]
    // --app already opens a dedicated window; a window flag next to it
    // either no-ops or opens a second empty one.
    if (appLaunch && (flag === "--new-window" || flag === "--new-tab")) continue
    if (entry.family === "firefox" && (flag === "--incognito" || flag === "--inprivate")) {
      args.push("--private-window")
    } else if (entry.family === "chromium" && flag === "--private-window") {
      args.push("--incognito")
    } else {
      args.push(flag)
    }
  }

  if (entry.manage) {
    args.push(MANAGE_URL[entry.family] || MANAGE_URL.chromium)
    return args
  }

  var targets = urls || []
  if (appLaunch) {
    if (targets[0]) args.push("--app=" + targets[0])
    return args
  }
  for (var u = 0; u < targets.length; u++) args.push(targets[u])
  return args
}

// ----------------------------------------------------------------- migration

// Import the v2 bash chooser's rules file. Its target was a case-insensitive
// substring of the menu label, so resolve it against the live entries the same
// way the old script did: first label that contains it, skipping manage rows.
function migrateLegacyRules(text, entries) {
  var rules = []
  var lines = stringValue(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) === "#") continue
    var parts = line.split(/\s+/)
    if (parts.length < 2) continue
    var pattern = parts[0].toLowerCase()
    var target = parts.slice(1).join(" ").toLowerCase()
    for (var e = 0; e < entries.length; e++) {
      if (entries[e].manage) continue
      if (entries[e].label.toLowerCase().indexOf(target) >= 0) {
        rules.push({ pattern: pattern, entryId: entries[e].id, learned: false })
        break
      }
    }
  }
  return rules
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    HALF_LIFE_DAYS: HALF_LIFE_DAYS,
    DOMAIN_WEIGHT: DOMAIN_WEIGHT,
    hostOf: hostOf,
    schemeOf: schemeOf,
    isZoomScheme: isZoomScheme,
    isZoomHost: isZoomHost,
    pathOf: pathOf,
    zoomMeetingId: zoomMeetingId,
    isZoomMeetingUrl: isZoomMeetingUrl,
    queryParam: queryParam,
    translateZoomUrl: translateZoomUrl,
    handlerMatches: handlerMatches,
    translateUrls: translateUrls,
    DEFAULT_SETTINGS: DEFAULT_SETTINGS,
    parseSettings: parseSettings,
    parseHandler: parseHandler,
    defaultHandlers: defaultHandlers,
    parseHandlers: parseHandlers,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    copyConfig: copyConfig,
    ruleMatches: ruleMatches,
    matchRule: matchRule,
    matchHandler: matchHandler,
    rankingHost: rankingHost,
    prepareRequest: prepareRequest,
    profileNameFromLabel: profileNameFromLabel,
    entriesForHandler: entriesForHandler,
    upsertRule: upsertRule,
    removeRule: removeRule,
    filterRules: filterRules,
    parseState: parseState,
    serializeState: serializeState,
    decayedScore: decayedScore,
    scoreFor: scoreFor,
    recordChoice: recordChoice,
    domainHits: domainHits,
    shouldOfferRule: shouldOfferRule,
    fuzzyScore: fuzzyScore,
    matches: matches,
    rankEntries: rankEntries,
    entryById: entryById,
    launchArgs: launchArgs,
    migrateLegacyRules: migrateLegacyRules
  }
}
