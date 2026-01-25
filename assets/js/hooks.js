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

/**
 * MentionsHandler Hook
 * Manages the @mention functionality in the chat textarea, including
 * searching for contacts, selecting them, and maintaining sync with the backend.
 */
Hooks.MentionsHandler = {
  mounted() {
    this.input = this.el.querySelector("textarea") || this.el;
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

    // Checks if the user is currently typing a mention.
    // Triggers a contact search if a trailing '@' or '@query' is found.
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

    // Disables the submit button if the input is empty or just whitespace.
    this.toggleSubmitButton = () => {
      const text = this.input.value.trim();
      const submitBtn = this.el
        .closest("form")
        .querySelector('button[type="submit"]');
      if (submitBtn) {
        submitBtn.disabled = text === "";
      }
    };

    // Event listeners for real-time updates
    this.input.addEventListener("input", () => {
      this.syncMentions();
      this.checkMentions();
      this.toggleSubmitButton();
    });

    this.input.addEventListener("keydown", (e) => {
      // Shift + Enter to submit the form
      if (e.key === "Enter" && e.shiftKey) {
        e.preventDefault();
        const form = this.el.closest("form");
        const submitBtn = form?.querySelector('button[type="submit"]');

        if (submitBtn && !submitBtn.disabled) {
          submitBtn.click();
        }
        return;
      }

      // Special handling for Backspace to delete entire mentions
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

      // Handle keyboard navigation when the mentions menu is open
      if (this.el.dataset.mentionsOpen === "true") {
        if (e.key === "Tab") {
          // Select the currently highlighted mention
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

    // Mouse listener to handle clicking on items in the mentions menu.
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

// SidebarResizer Hook - Enables draggable resizing for the CRM chat sidebar.
Hooks.SidebarResizer = {
  mounted() {
    this.handle = this.el;
    this.container = document.getElementById("crm-chat-sidebar-container");
    this.isResizing = false;

    if (!this.container) {
      console.warn(
        "SidebarResizer: Container #crm-chat-sidebar-container not found",
      );
      return;
    }

    // Initializes the resizing process on mouse down.
    this.startResize = (e) => {
      e.preventDefault();
      this.isResizing = true;
      this.container.classList.add("resizing");
      document.body.style.userSelect = "none";
      document.body.style.cursor = "col-resize";

      this.handle.classList.add("bg-indigo-500", "opacity-100");

      document.addEventListener("mousemove", this.doResize);
      document.addEventListener("mouseup", this.stopResize);
    };

    // Calculates and applies the new width during mouse movement.
    this.doResize = (e) => {
      if (
        !this.isResizing ||
        this.container.classList.contains("collapsed-sidebar")
      )
        return;

      // Calculate new width (Right Sidebar: Width = Window Width - Mouse X)
      // Clamped between 300px and 800px
      let newWidth = window.innerWidth - e.clientX;
      if (newWidth < 300) newWidth = 300;
      if (newWidth > 800) newWidth = 800;

      this.container.style.width = `${newWidth}px`;
    };

    // Cleans up listeners and styles after resizing is finished.
    this.stopResize = () => {
      this.isResizing = false;
      this.container.classList.remove("resizing");
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      this.handle.classList.remove("bg-indigo-500", "opacity-100");

      document.removeEventListener("mousemove", this.doResize);
      document.removeEventListener("mouseup", this.stopResize);
    };

    this.handle.addEventListener("mousedown", this.startResize);
  },

  destroyed() {
    if (this.handle) {
      this.handle.removeEventListener("mousedown", this.startResize);
    }
    // Cleanup global listeners
    document.removeEventListener("mousemove", this.doResize);
    document.removeEventListener("mouseup", this.stopResize);
  },
};

export default Hooks;
