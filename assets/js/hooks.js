let Hooks = {};

Hooks.Clipboard = {
  mounted() {
    this.handleEvent("copy-to-clipboard", ({ text: text }) => {
      navigator.clipboard.writeText(text).then(() => {
        this.pushEventTo(this.el, "copied-to-clipboard", { text: text });
        setTimeout(() => {
          this.pushEventTo(this.el, "reset-copied", {});
        }, 2000);
      });
    });
  },
};

Hooks.MentionsHandler = {
  mounted() {
    // Select the textarea inside the ignored container
    this.input = this.el.querySelector("textarea");
    if (!this.input) {
      this.input = this.el;
    }
    this.activeMentions = [];

    this.syncMentions = () => {
      const text = this.input.value;
      const stillPresent = [];
      const removed = [];

      this.activeMentions.forEach((m) => {
        if (text.includes(`@${m.name} `)) {
          stillPresent.push(m);
        } else {
          removed.push(m);
        }
      });

      if (removed.length > 0) {
        this.activeMentions = stillPresent;
        removed.forEach((m) => {
          this.pushEvent("remove_contact", { id: m.id, provider: m.provider });
        });
      }
    };

    this.replaceWithMention = (name, id, provider) => {
      const currentMsg = this.input.value;
      const regex = /@[^\s]*$/;
      const match = currentMsg.match(regex);

      let newMsg;
      if (match) {
        newMsg = currentMsg.substring(0, match.index) + `@${name} `;
      } else {
        newMsg = currentMsg + `@${name} `;
      }

      if (
        !this.activeMentions.some((m) => m.id === id && m.provider === provider)
      ) {
        this.activeMentions.push({ name, id, provider });
      }

      this.input.value = newMsg;
      this.input.focus();
      this.input.dispatchEvent(new Event("input", { bubbles: true }));
    };

    this.handleEvent("clear-input", () => {
      this.input.value = "";
      this.activeMentions = [];
      const submitBtn = this.el
        .closest("form")
        .querySelector('button[type="submit"]');
      if (submitBtn) {
        submitBtn.disabled = true;
        submitBtn.classList.add(
          "disabled:opacity-50",
          "disabled:hover:bg-gray-200",
          "disabled:hover:text-gray-500",
        );
      }
    });

    this.checkMentions = () => {
      const text = this.input.value;
      const regex = /@([^\s]*)$/;
      const match = text.match(regex);

      if (match) {
        const query = match[1];
        this.pushEvent("search_contacts_direct", { query: query });
      } else {
        if (this.el.dataset.mentionsOpen === "true") {
          this.pushEvent("close_mentions", {});
        }
      }
    };

    this.toggleSubmitButton = () => {
      const text = this.input.value.trim();
      const submitBtn = this.el
        .closest("form")
        .querySelector('button[type="submit"]');
      if (submitBtn) {
        submitBtn.disabled = text === "";
      }
    };

    this.input.addEventListener("input", () => {
      this.syncMentions();
      this.checkMentions();
      this.toggleSubmitButton();
    });

    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Backspace") {
        const start = this.input.selectionStart;
        const end = this.input.selectionEnd;

        if (start === end && start > 0) {
          const text = this.input.value;
          const mention = this.activeMentions.find((m) => {
            const fullMention = `@${m.name} `;
            return text.substring(0, start).endsWith(fullMention);
          });

          if (mention) {
            e.preventDefault();
            const fullMention = `@${mention.name} `;
            const newText =
              text.substring(0, start - fullMention.length) +
              text.substring(start);
            this.input.value = newText;
            const newPos = start - fullMention.length;
            this.input.setSelectionRange(newPos, newPos);
            this.input.dispatchEvent(new Event("input", { bubbles: true }));
            return;
          }
        }
      }

      if (this.el.dataset.mentionsOpen === "true") {
        if (e.key === "Tab") {
          e.preventDefault();
          const menu = document.getElementById("mentions-menu");
          if (menu) {
            const highlighted = menu.querySelector(".mention-highlighted");
            if (highlighted) {
              const name = highlighted.dataset.name;
              const id = highlighted.getAttribute("phx-value-id");
              const provider = highlighted.getAttribute("phx-value-provider");

              this.replaceWithMention(name, id, provider);
              this.pushEvent("select_contact", { id: id, provider: provider });
            }
          }
        } else if (e.key === "ArrowUp" || e.key === "ArrowDown") {
          e.preventDefault();
          this.pushEvent("handle_keydown", { key: e.key });
        }
      }
    });

    this.clickListener = (e) => {
      const item = e.target.closest(".mention-item");
      if (item && document.getElementById("mentions-menu")?.contains(item)) {
        e.preventDefault();
        e.stopPropagation();

        const name = item.dataset.name;
        const id = item.getAttribute("phx-value-id");
        const provider = item.getAttribute("phx-value-provider");

        this.replaceWithMention(name, id, provider);
        this.pushEvent("select_contact", { id: id, provider: provider });
      }
    };

    document.addEventListener("mousedown", this.clickListener);
  },

  destroyed() {
    document.removeEventListener("mousedown", this.clickListener);
  },
};

export default Hooks;
