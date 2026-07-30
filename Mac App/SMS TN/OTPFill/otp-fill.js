// Shared OTP field detection + fill. Loaded both as a content script (for
// automatic fill) and injected by the popup (for the manual force/retry).
// Attaches window.__otpFill with: qualifies(strict) and run(code, {strict}).
//
// strict = automatic: only a strong OTP field, and only if it's empty.
// non-strict = manual force: looser match, may overwrite.

(function () {
  if (window.__otpFill) return;

  function isVisible(el) {
    if (!el || el.disabled || el.readOnly) return false;
    const s = window.getComputedStyle(el);
    if (s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function setNativeValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  const KEYWORDS = [
    "one-time-code", "onetimecode", "one time code", "otp", "totp", "mfa", "2fa",
    "verification", "verify", "verificacao", "verificar",
    "code", "codigo", "passcode", "pin", "token", "sms",
    "security code", "securitycode", "sms token", "codigo sms",
    "auth", "authentication", "seguranca", "confirmacao", "confirmar",
  ];
  function norm(s) {
    return (s || "").toString().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
  }
  const KWN = KEYWORDS.map(norm);
  function hasKW(s) { const n = norm(s); return !!n && KWN.some((k) => n.includes(k)); }

  function editable(el) {
    const t = (el.type || "text").toLowerCase();
    return ["text", "tel", "number", "password", ""].includes(t) && !el.disabled && !el.readOnly;
  }
  function labelText(el) {
    let t = "";
    try {
      if (el.id) { const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`); if (l) t += " " + l.textContent; }
    } catch (e) {}
    const wrap = el.closest && el.closest("label"); if (wrap) t += " " + wrap.textContent;
    const alb = el.getAttribute("aria-labelledby");
    if (alb) alb.split(/\s+/).forEach((id) => { const n = document.getElementById(id); if (n) t += " " + n.textContent; });
    return t;
  }
  function nearbyText(el) {
    let t = "", node = el, hops = 0;
    while (node && hops < 4) {
      let sib = node.previousElementSibling, c = 0;
      while (sib && c < 3) { t += " " + (sib.textContent || ""); sib = sib.previousElementSibling; c++; }
      node = node.parentElement; hops++;
    }
    return t;
  }

  // Score one field. Returns { score, kw } where kw means an OTP wording signal
  // is present (attribute, label, or nearby text) — required for auto-fill.
  function scoreField(el, digits) {
    const type = (el.type || "text").toLowerCase();
    const ac = norm(el.getAttribute("autocomplete"));
    const attrs = [el.name, el.id, el.className, el.getAttribute("placeholder"),
      el.getAttribute("aria-label"), el.getAttribute("title"), ac].join(" ");
    const kwAttr = hasKW(attrs), kwLbl = hasKW(labelText(el)), kwNear = hasKW(nearbyText(el));
    const kw = kwAttr || kwLbl || kwNear || ac.includes("one-time-code");

    let score = 0;
    if (ac.includes("one-time-code")) score += 100;
    if (norm(el.inputMode) === "numeric") score += 25;
    if (type === "tel" || type === "number") score += 15;
    const ml = parseInt(el.getAttribute("maxlength"), 10);
    if (ml >= 4 && ml <= 8) score += 25;
    if (ml === digits.length) score += 15;
    if (kwAttr) score += 60;
    if (kwLbl) score += 60;
    if (kwNear) score += 30;
    const pat = el.getAttribute("pattern") || ""; if (/\\d|0-9|\d/.test(pat)) score += 15;

    // A password field only qualifies with an OTP signal, so the code never
    // lands in a plain login-password box.
    if (type === "password" && !kw) score = 0;
    return { score, kw };
  }

  function findBest(digits) {
    const inputs = Array.from(document.querySelectorAll("input")).filter((el) => isVisible(el) && editable(el));
    let best = null, bestScore = 0, bestKW = false;
    for (const el of inputs) {
      const { score, kw } = scoreField(el, digits);
      if (score > bestScore) { bestScore = score; best = el; bestKW = kw; }
    }
    return { el: best, score: bestScore, kw: bestKW };
  }

  function segmentedGroup(digits) {
    const singles = Array.from(document.querySelectorAll("input")).filter((el) =>
      isVisible(el)
      && (el.maxLength === 1 || el.getAttribute("maxlength") === "1")
      && (el.inputMode === "numeric" || el.type === "tel" || el.type === "number" || el.type === "text"));
    if (singles.length >= digits.length && singles.length <= 12) return singles;
    return null;
  }

  function editableInputs() {
    return Array.from(document.querySelectorAll("input")).filter((el) => isVisible(el) && editable(el));
  }
  function pageOtpContext() {
    return hasKW(((document.body && document.body.innerText) || "").slice(0, 8000));
  }

  // Does a fillable field exist right now? Used by the content script to decide
  // whether it is worth asking the app for a code.
  function qualifies(strict) {
    const digits = "000000"; // length-agnostic probe
    if (segmentedGroup(digits)) return true;
    const b = findBest(digits);
    if (b.el && (strict ? (b.score >= 70 && b.kw) : (b.score >= 40))) return true;
    // Dedicated OTP page: one editable field + code/SMS wording on the page.
    const inputs = editableInputs();
    if (inputs.length === 1 && pageOtpContext()) {
      return strict ? (inputs[0].value || "").trim() === "" : true;
    }
    return false;
  }

  // Fill. Returns "filled" | "nofield".
  function run(code, opts) {
    opts = opts || {};
    const strict = !!opts.strict;
    const digits = String(code).replace(/\D/g, "");
    if (!digits) return "nofield";

    // 1) Segmented OTP boxes.
    const seg = segmentedGroup(digits);
    if (seg) {
      if (!strict || !seg.slice(0, digits.length).some((el) => (el.value || "") !== "")) {
        for (let i = 0; i < digits.length; i++) setNativeValue(seg[i], digits[i]);
        try { seg[Math.min(digits.length, seg.length) - 1].focus(); } catch (e) {}
        return "filled";
      }
    }

    // 2) Best-scoring OTP field.
    const b = findBest(digits);
    if (b.el) {
      const ok = strict
        ? (b.score >= 70 && b.kw && (b.el.value || "").trim() === "")
        : (b.score >= 40);
      if (ok) { setNativeValue(b.el, digits); try { b.el.focus(); } catch (e) {} return "filled"; }
    }

    // 3) Dedicated OTP page: exactly one editable field + code/SMS wording.
    const inputs = editableInputs();
    if (inputs.length === 1 && pageOtpContext()) {
      const el = inputs[0];
      if (!strict || (el.value || "").trim() === "") {
        setNativeValue(el, digits); try { el.focus(); } catch (e) {}
        return "filled";
      }
    }

    // 4) Manual force only: whatever input is focused.
    if (!strict) {
      const ae = document.activeElement;
      if (ae && ae.tagName === "INPUT" && isVisible(ae) && editable(ae)) {
        setNativeValue(ae, digits); return "filled";
      }
    }
    return "nofield";
  }

  window.__otpFill = { qualifies, run };
})();
