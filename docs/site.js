// The hint mode of this page, following the rules of the app:
// labels never start with another label, and one remaining match clicks.
(() => {
  const CHARACTERS = "sadfjklewcmpgh";
  const TAP_LIMIT_MS = 300;

  const status = document.querySelector(".hint-status");
  let session = null;
  let tapStartedAt = null;

  function makeLabels(count) {
    const hints = [""];
    let offset = 0;
    while (hints.length - offset < count || hints.length === 1) {
      const hint = hints[offset];
      offset += 1;
      for (const character of CHARACTERS) hints.push(character + hint);
    }
    return hints
      .slice(offset, offset + count)
      .sort()
      .map((hint) => [...hint].reverse().join(""));
  }

  function visibleTargets() {
    return [...document.querySelectorAll("a[href], button:not([data-try])")].filter((element) => {
      const rect = element.getBoundingClientRect();
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        rect.bottom > 0 &&
        rect.right > 0 &&
        rect.top < window.innerHeight &&
        rect.left < window.innerWidth
      );
    });
  }

  function enter() {
    const targets = visibleTargets();
    const labels = makeLabels(targets.length);
    const layer = document.createElement("div");
    layer.className = "hint-layer";
    layer.setAttribute("aria-hidden", "true");

    const items = targets.map((target, index) => {
      const rect = target.getBoundingClientRect();
      const node = document.createElement("span");
      node.className = "hint";
      node.style.left = `${Math.max(2, rect.left - 10)}px`;
      node.style.top = `${Math.max(2, rect.top - 14)}px`;
      layer.append(node);
      return { label: labels[index], target, node };
    });

    document.body.append(layer);
    status.hidden = false;
    session = { items, layer, typed: "" };
    render();
  }

  function exit() {
    if (session === null) return;
    session.layer.remove();
    status.hidden = true;
    session = null;
  }

  function render() {
    for (const { label, node } of session.items) {
      node.hidden = !label.startsWith(session.typed);
      const typed = document.createElement("span");
      typed.className = "typed";
      typed.textContent = session.typed;
      node.replaceChildren(typed, label.slice(session.typed.length));
    }
  }

  function typeCharacter(character) {
    const typed = session.typed + character;
    const matches = session.items.filter(({ label }) => label.startsWith(typed));
    if (matches.length === 0) return;
    if (matches.length === 1) {
      const { target } = matches[0];
      exit();
      target.click();
      return;
    }
    session.typed = typed;
    render();
  }

  document.addEventListener(
    "keydown",
    (event) => {
      tapStartedAt = event.code === "MetaRight" && !event.repeat ? performance.now() : null;
      if (session === null) return;

      if (event.key === "Escape") {
        event.preventDefault();
        exit();
        return;
      }
      if (event.metaKey || event.ctrlKey || event.altKey) return;

      event.preventDefault();
      if (event.key === "Backspace") {
        session.typed = session.typed.slice(0, -1);
        render();
      } else if (event.key.length === 1) {
        typeCharacter(event.key.toLowerCase());
      }
    },
    true,
  );

  document.addEventListener("keyup", (event) => {
    if (event.code !== "MetaRight" || tapStartedAt === null) return;
    const isTap = performance.now() - tapStartedAt <= TAP_LIMIT_MS;
    tapStartedAt = null;
    if (!isTap) return;
    if (session === null) enter();
    else exit();
  });

  document.addEventListener("pointerdown", (event) => {
    if (!event.target.closest("[data-try]")) exit();
  });
  window.addEventListener("scroll", exit, { passive: true });
  window.addEventListener("resize", exit);
  window.addEventListener("blur", exit);

  document.querySelector("[data-try]").addEventListener("click", () => {
    if (session === null) enter();
    else exit();
  });

  // Copy buttons
  for (const button of document.querySelectorAll(".copy")) {
    const idleText = button.textContent;
    button.addEventListener("click", async () => {
      const code = button.parentElement.querySelector("code");
      try {
        await navigator.clipboard.writeText(code.textContent);
        button.textContent = button.dataset.done;
      } catch {
        button.textContent = button.dataset.failed;
      }
      setTimeout(() => {
        button.textContent = idleText;
      }, 1600);
    });
  }
})();
