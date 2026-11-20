(() => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ytdl-safari-download";
    button.textContent = browser.i18n.getMessage("download");
    button.title = browser.i18n.getMessage("downloadDescription");
    button.setAttribute("aria-label", button.title);

    function videoID() {
        if (location.pathname !== "/watch") return null;
        const id = new URL(location.href).searchParams.get("v");
        return id && /^[\w-]{11}$/.test(id) ? id : null;
    }

    button.addEventListener("click", (event) => {
        event.stopPropagation();
        const id = videoID();
        if (event.isTrusted && id) location.href = `ytdl://youtube/video/${id}`;
    });

    function placeButton() {
        const actions = videoID() && document.querySelector(
            "ytd-watch-flexy:not([hidden]) #actions #top-level-buttons-computed"
        );
        if (!actions) {
            button.remove();
            return;
        }
        const reactions = actions.querySelector(
            "segmented-like-dislike-button-view-model, ytd-segmented-like-dislike-button-renderer"
        );
        const anchor = reactions?.closest("#top-level-buttons-computed > *");
        if (!anchor) {
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
        });
    }

    new MutationObserver(update).observe(document.body, { childList: true, subtree: true });
    document.addEventListener("yt-navigate-finish", update);
    window.addEventListener("popstate", update);
    update();
})();
