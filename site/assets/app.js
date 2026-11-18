/* CPZ site: language switching. No dependencies. */
(function () {
  "use strict";

  var supported = ["en", "uk", "pl", "de", "fr", "es", "it", "pt", "tr", "ja", "zh"];
  var langTag = { pt: "pt-BR", zh: "zh-CN" };
  var cache = new Map();
  var loadToken = 0;

  var select = document.getElementById("lang-select");

  function normalizeLang(value) {
    if (!value) return null;
    var code = String(value).toLowerCase().replace("_", "-");
    var base = code.split("-")[0];
    if (base === "pt") return "pt";
    if (base === "zh") return "zh";
    return supported.indexOf(base) >= 0 ? base : null;
  }

  function pickInitialLang() {
    var fromUrl = normalizeLang(new URLSearchParams(window.location.search).get("lang"));
    if (fromUrl) return fromUrl;
    try {
      var saved = normalizeLang(window.localStorage.getItem("cpz.lang"));
      if (saved) return saved;
    } catch (e) {
      /* storage may be unavailable */
    }
    var list = navigator.languages || [navigator.language || "en"];
    for (var i = 0; i < list.length; i++) {
      var found = normalizeLang(list[i]);
      if (found) return found;
    }
    return "en";
  }

  function applyMessages(lang, data) {
    document.documentElement.lang = langTag[lang] || lang;
    document.title = data["meta.title"] || document.title;
    var desc = document.querySelector('meta[name="description"]');
    if (desc && data["meta.desc"]) desc.setAttribute("content", data["meta.desc"]);

    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var text = data[el.getAttribute("data-i18n")];
      if (typeof text === "string") el.textContent = text;
    });

    document.querySelectorAll("[data-i18n-aria-label]").forEach(function (el) {
      var text = data[el.getAttribute("data-i18n-aria-label")];
      if (typeof text === "string") el.setAttribute("aria-label", text);
    });
  }

  function setUrl(lang) {
    var url = new URL(window.location.href);
    if (lang === "en") url.searchParams.delete("lang");
    else url.searchParams.set("lang", lang);
    window.history.replaceState(null, "", url);
  }

  async function loadLanguage(lang, updateUrl) {
    lang = supported.indexOf(lang) >= 0 ? lang : "en";
    var token = ++loadToken;
    var data = cache.get(lang);

    if (!data) {
      try {
        var response = await fetch("i18n/" + lang + ".json", { cache: "no-cache" });
        if (!response.ok) throw new Error("HTTP " + response.status);
        data = await response.json();
        cache.set(lang, data);
      } catch (error) {
        if (lang !== "en") {
          if (select) select.value = "en";
          return loadLanguage("en", updateUrl);
        }
        return;
      }
    }

    if (token !== loadToken) return;
    applyMessages(lang, data);
    if (select) select.value = lang;
    try {
      window.localStorage.setItem("cpz.lang", lang);
    } catch (e) {
      /* ignore */
    }
    if (updateUrl) setUrl(lang);
  }

  if (select) {
    select.addEventListener("change", function () {
      loadLanguage(select.value, true);
    });
  }

  loadLanguage(pickInitialLang(), true);
})();
