/* Remembers whether today's spelling is written on screen or on paper. */
(function (global) {
  function torontoYmd() {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Toronto",
      year: "numeric",
      month: "2-digit",
      day: "2-digit"
    }).format(new Date());
  }

  function key(lang) {
    const profile = (global.Baeren && Baeren.cfg().profile) || "AM";
    return "baerenSpellMode:" + profile + ":" + (lang === "fr" ? "fr" : "eng") + ":" + torontoYmd();
  }

  function get(lang) {
    const mode = localStorage.getItem(key(lang));
    return mode === "paper" || mode === "screen" ? mode : "";
  }

  function set(lang, mode) {
    if (mode !== "paper" && mode !== "screen") return;
    localStorage.setItem(key(lang), mode);
  }

  async function hasPrefix(prefix) {
    const c = global.Baeren && Baeren.cfg();
    if (!c || !c.url || !c.key) return false;
    const pattern = prefix + "-" + torontoYmd() + "-%";
    const url = c.url + "/rest/v1/image_uploads?profile=eq." + encodeURIComponent(c.profile)
      + "&task=like." + encodeURIComponent(pattern)
      + "&select=id&limit=1";
    const res = await fetch(url, {
      headers: { apikey: c.key, Authorization: "Bearer " + c.key }
    });
    if (!res.ok) return false;
    const rows = await res.json();
    return Array.isArray(rows) && rows.length > 0;
  }

  async function infer(lang) {
    const french = lang === "fr";
    const screenPrefix = french ? "FrSpellingOCR" : "EngSpellingOCR";
    const paperPrefix = french ? "FrSpellingOCRPaper" : "EngSpellingOCRPaper";
    try {
      if (await hasPrefix(screenPrefix)) return "screen";
      if (await hasPrefix(paperPrefix)) return "paper";
    } catch (e) {
      console.warn(e);
    }
    return "";
  }

  function go(next, mode, params) {
    const q = new URLSearchParams(params);
    q.delete("next");
    const page = next === "xtra"
      ? (mode === "paper" ? "xtra.html" : "xtra-screen.html")
      : (mode === "paper" ? "paper.html" : "spell.html");
    location.replace(page + "?" + q.toString());
  }

  global.SpellMode = { get: get, set: set, infer: infer, go: go };
})(window);
