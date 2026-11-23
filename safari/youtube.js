(() => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ytdl-safari-download";
    button.setAttribute("aria-label", browser.i18n.getMessage("downloadDescription"));

    const icon = document.createElement("span");
    icon.className = "ytdl-safari-download-icon";
    icon.setAttribute("aria-hidden", "true");
    button.append(icon);

    const tooltip = document.createElement("div");
    tooltip.className = "ytdl-safari-tooltip";
    tooltip.textContent = browser.i18n.getMessage("download");
    tooltip.setAttribute("aria-hidden", "true");

    function hideTooltip() {
        tooltip.remove();
    }

    function positionTooltip() {
        if (!tooltip.isConnected || !button.isConnected) return;

        // Measure both elements in the same coordinate space during pinch zoom.
        const anchor = button.getBoundingClientRect();
        const bubble = tooltip.getBoundingClientRect();
        const horizontalDelta = anchor.left + anchor.width / 2 - (bubble.left + bubble.width / 2);
        const verticalDelta = anchor.bottom + 16 - bubble.top;
        tooltip.style.left = `${parseFloat(tooltip.style.left) + horizontalDelta}px`;
        tooltip.style.top = `${parseFloat(tooltip.style.top) + verticalDelta}px`;
    }

    function showTooltip() {
        if (!button.isConnected) return;
        if (!tooltip.isConnected) {
            tooltip.style.left = "0px";
            tooltip.style.top = "0px";
            document.body.append(tooltip);
        }
        positionTooltip();
    }

    button.addEventListener("mouseenter", showTooltip);
    button.addEventListener("mouseleave", hideTooltip);
    button.addEventListener("focus", () => {
        if (button.matches(":focus-visible")) showTooltip();
    });
    button.addEventListener("blur", hideTooltip);
    button.addEventListener("keydown", (event) => {
        if (event.key === "Escape") hideTooltip();
    });
    window.addEventListener("scroll", positionTooltip, { capture: true, passive: true });
    window.addEventListener("resize", positionTooltip);
    window.visualViewport?.addEventListener("scroll", positionTooltip);
    window.visualViewport?.addEventListener("resize", positionTooltip);

    function videoID() {
        if (location.pathname !== "/watch") return null;
        const id = new URL(location.href).searchParams.get("v");
        return id && /^[\w-]{11}$/.test(id) ? id : null;
    }

    button.addEventListener("click", (event) => {
        hideTooltip();
        event.stopPropagation();
        const id = videoID();
        if (event.isTrusted && id) location.href = `ytdl://youtube/video/${id}`;
    });

    function placeButton() {
        const actions = videoID() && document.querySelector(
            "ytd-watch-flexy:not([hidden]) #actions #top-level-buttons-computed"
        );
        if (!actions) {
            hideTooltip();
            button.remove();
            return;
        }
        const reactions = actions.querySelector(
            "segmented-like-dislike-button-view-model, ytd-segmented-like-dislike-button-renderer"
        );
        const anchor = reactions?.closest("#top-level-buttons-computed > *");
        if (!anchor) {
            hideTooltip();
            button.remove();
        } else if (anchor.nextElementSibling !== button) {
            anchor.after(button);
        }
    }

    let frame = null;
    function update() {
        if (frame !== null) return;
        frame = requestAnimationFrame(() => {
            frame = null;
            placeButton();
            positionTooltip();
        });
    }

    new MutationObserver(update).observe(document.body, { childList: true, subtree: true });
    document.addEventListener("yt-navigate-finish", update);
    window.addEventListener("popstate", update);
    update();
})();
