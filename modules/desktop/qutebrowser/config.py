## Documentation:
##   qute://help/configuring.html
##   qute://help/settings.html
## qute://settings/


import theme

c.auto_save.session = True
# c.backend = 'webengine'
c.changelog_after_upgrade = "patch"
c.auto_save.interval = (
    15000  # Time interval (in milliseconds) between auto-saves of config/cookies/etc.
)
c.aliases = {
    "w": "session-save",
    "q": "close",
    "qa": "quit",
    "wq": "quit --save",
    "wqa": "quit --save",
}
config.load_autoconfig(True)
c.bindings.key_mappings = {
    "<Ctrl-[>": "<Escape>",
    "<Ctrl-6>": "<Ctrl-^>",
    "<Ctrl-M>": "<Return>",
    "<Ctrl-J>": "<Return>",
    "<Ctrl-I>": "<Tab>",
    "<Shift-Return>": "<Return>",
    "<Enter>": "<Return>",
    "<Shift-Enter>": "<Return>",
    "<Ctrl-Enter>": "<Ctrl-Return>",
}


c.completion.cmd_history_max_items = 60  # 0: no history, -1 unlimited
c.completion.delay = 0
# c.completion.favorite_paths = [] # Default filesystem autocomplete suggestions for :open.
c.completion.height = theme.DIM_H  # Percent or int pixel
c.completion.min_chars = 1
c.completion.open_categories = [
    "searchengines",
    "quickmarks",
    "bookmarks",
    "history",
    "filesystem",
]
c.completion.quick = True
c.completion.scrollbar.padding = 0  # pixels scrollbar handle in the completion window.
c.completion.scrollbar.width = (
    theme.DIM_S
)  # Width (in pixels) of the scrollbar in the completion window.
c.completion.show = "always"  # auto, always, never
c.completion.shrink = True  # Shrink the completion to be smaller than the configured size if there are no scrollbars.
c.completion.timestamp_format = "%Y-%m-%d %H:%M"
# c.completion.use_best_match = False # Execute the best-matching command on a partial match.
c.completion.web_history.max_items = (
    720  # Number of URLs to show in the web history. 0: no history / -1: unlimited
)

c.confirm_quit = [
    "downloads"
]  # Require a confirmation before quitting the application. always, multiple-tabs, downloads, never

c.content.autoplay = False
c.content.blocking.enabled = False  # Enable the ad/host blocker
# c.content.cookies.accept = 'all' # no-3rdparty: Accept cookies from the same origin only. This is known to break some sites, such as GMail.
c.content.cookies.store = True
# c.content.default_encoding = 'iso-8859-1' # Default encoding to use for websites. The encoding must be a string describing an encoding such as _utf-8_, _iso-8859-1_, etc.
# c.content.frame_flattening = False # Expand each subframe to its contents. This will flatten all the frames to become one scrollable page.
# c.content.fullscreen.overlay_timeout = 3000 # Set fullscreen notification overlay timeout in milliseconds. If set to 0, no overlay will be displayed.
# c.content.fullscreen.window = False # Limit fullscreen to the browser window (does not expand to fill the screen).

c.content.headers.accept_language = "tr-TR,en-US,en;q=0.9"
# c.content.headers.custom = {} # Custom headers for qutebrowser HTTP requests.
c.content.headers.do_not_track = True
# c.content.headers.referer = 'same-domain' # When to send the Referer header. The Referer header tells websites from which website you were coming from when visiting them. always, never, same-domain
# c.content.headers.user_agent = 'Mozilla/5.0 ({os_info}) AppleWebKit/{webkit_version} (KHTML, like Gecko) {upstream_browser_key}/{upstream_browser_version_short} Safari/{webkit_version}'

# c.content.images = True # Load images automatically in web pages.
# c.content.javascript.can_close_tabs = False
# c.content.javascript.can_open_tabs_automatically = False
# c.content.notifications.presenter = 'auto'
c.content.notifications.show_origin = False  # Show the origin URL for notifications.
c.content.pdfjs = True  ## Display PDF files via PDF.js in the browser without showing a download prompt. Note that the files can still be downloaded by clicking the download button in the pdf.js viewer. With this set to `false`, the  `:prompt-open-download --pdfjs` command (bound to `<Ctrl-p>` by  default) can be used in the download prompt.
c.content.prefers_reduced_motion = (
    True  # Request websites to minimize non-essentials animations and motion.
)
# c.content.print_element_backgrounds = True # Draw the background color and images also when the page is printed.
# c.content.private_browsing = False # Open new windows in private browsing mode which does not record visited pages.
c.content.user_stylesheets = []
# c.content.webgl = True

c.downloads.location.directory = None
c.downloads.location.prompt = True
c.downloads.location.remember = True
c.downloads.location.suggestion = "both"  # path, filename, both
c.downloads.position = "top"  # bottom, top

# c.editor.command = ['gvim', '-f', '{file}', '-c', 'normal {line}G{column0}l']
# c.editor.encoding = 'utf-8'
# c.editor.remove_file = True

# c.fileselect.folder.command = ['xterm', '-e', 'ranger', '--choosedir={}']
# c.fileselect.handler = 'default'
# c.fileselect.multiple_files.command = ['xterm', '-e', 'ranger', '--choosefiles={}']
# c.fileselect.single_file.command = ['xterm', '-e', 'ranger', '--choosefile={}']

# c.hints.auto_follow = 'unique-match' ## When a hint can be automatically followed without pressing Enter. ##   - always ##   - unique-match ##   - full-match ##   - never
c.hints.auto_follow_timeout = 0  # Duration (in milliseconds) to ignore normal-mode key bindings after a successful auto-follow.
c.hints.border = "none"  # CSS border value for hints.
c.hints.chars = "asdfghjkl"  # Characters used for hint strings.
# c.hints.dictionary = '/usr/share/dict/words' # Dictionary file to be used by the word hints.
# c.hints.hide_unmatched_rapid_hints = True # Hide unmatched hints in rapid mode.
# c.hints.leave_on_load = False # Leave hint mode when starting a new page load.
# c.hints.min_chars = 1 # Minimum number of characters used for hint strings.
# c.hints.mode = 'letter' # number, letter, word
# c.hints.next_regexes = ['\\bnext\\b', '\\bmore\\b', '\\bnewer\\b', '\\b[>→≫]\\b', '\\b(>>|»)\\b', '\\bcontinue\\b'] ## Comma-separated list of regular expressions to use for 'next' links.
c.hints.padding = {"top": 5, "bottom": 5, "left": 5, "right": 5}
# c.hints.prev_regexes = ['\\bprev(ious)?\\b', '\\bback\\b', '\\bolder\\b', '\\b[<←≪]\\b', '\\b(<<|«)\\b'] # Comma-separated list of regular expressions to use for 'prev' links.
c.hints.radius = 0
# c.hints.scatter = True
# c.hints.selectors = {'all': ['a', 'area', 'textarea', 'select', 'input:not([type="hidden"])', 'button', 'frame', 'iframe', 'img', 'link', 'summary', '[contenteditable]:not([contenteditable="false"])', '[onclick]', '[onmousedown]', '[role="link"]', '[role="option"]', '[role="button"]', '[role="tab"]', '[role="checkbox"]', '[role="switch"]', '[role="menuitem"]', '[role="menuitemcheckbox"]', '[role="menuitemradio"]', '[role="treeitem"]', '[aria-haspopup]', '[ng-click]', '[ngClick]', '[data-ng-click]', '[x-ng-click]', '[tabindex]:not([tabindex="-1"])'], 'links': ['a[href]', 'area[href]', 'link[href]', '[role="link"][href]'], 'images': ['img'], 'media': ['audio', 'img', 'video'], 'url': ['[src]', '[href]'], 'inputs': ['input[type="text"]', 'input[type="date"]', 'input[type="datetime-local"]', 'input[type="email"]', 'input[type="month"]', 'input[type="number"]', 'input[type="password"]', 'input[type="search"]', 'input[type="tel"]', 'input[type="time"]', 'input[type="url"]', 'input[type="week"]', 'input:not([type])', '[contenteditable]:not([contenteditable="false"])', 'textarea']}
# c.hints.uppercase = False # Make characters in hint strings uppercase.

# c.history_gap_interval = 30 # Maximum time (in minutes) between two history items for them to be Use -1 to disable separation.

# c.input.escape_quits_reporter = True # Allow Escape to quit the crash reporter.
# c.input.forward_unbound_keys = 'auto' # Which unbound keys to forward to the webview in normal mode. - all: Forward all unbound keys. - auto: Forward unbound non-alphanumeric keys. - none: Don't forward any keys.
c.input.insert_mode.auto_enter = (
    True  # Enter insert mode if an editable element is clicked.
)
c.input.insert_mode.auto_leave = (
    True  # Leave insert mode if a non-editable element is clicked.
)
c.input.insert_mode.auto_load = True  # Automatically enter insert mode if an editable element is focused after loading the page.
# c.input.insert_mode.leave_on_load = True # Leave insert mode when starting a new page load
# c.input.insert_mode.plugins = False ## Switch to insert mode when clicking flash and other plugins.
# c.input.links_included_in_focus_chain = True ## Include hyperlinks in the keyboard focus chain when tabbing.
# c.input.match_counts = True # Interpret number prefixes as counts for bindings.
# c.input.media_keys = True # Whether the underlying Chromium should handle media keys. On Linux, disabling this also disables Chromium's MPRIS integration.
# c.input.spatial_navigation = False  # Enable spatial navigation. Spatial navigation consists in the ability to navigate between focusable elements, such as hyperlinks and form controls, on a web page by using the Left, Right, Up and Down arrow keys.

# c.keyhint.blacklist = [] # Type: List of String Keychains that shouldn't be shown in the keyhint dialog. Globs are supported, so `;*` will blacklist all keychains starting with `;`. Use `*` to disable keyhints.
# c.keyhint.delay = 500
c.keyhint.radius = 0

c.logging.level.console = "debug"

c.messages.timeout = 0  # 0 never clear, milliseconds

c.new_instance_open_target = "tab-bg-silent"  # tab, tab-bg, tab-bg-silent, tab-silent (silent: dont select browser window, bg: dont select new tab)
c.new_instance_open_target_window = (
    "last-focused"  # last-visible, last-focused, last-opened, first-opened
)

c.prompt.filebrowser = True  # Show a filebrowser in download prompts.
c.prompt.radius = 0  # Rounding radius (in pixels) for the edges of prompts.

# c.qt.args = [] # Additional arguments to pass to Qt, without leading `--`.
c.qt.chromium.low_end_device_mode = "never"  # When to use Chromium's low-end device mode. This improves the RAM usage of renderer processes, at the expense of performance. (always, never, auto [< 1 GB available ram])
# c.qt.chromium.process_model = 'process-per-site-instance' # process-per-site-instance, process-per-site, single-process
# c.qt.chromium.sandboxing = 'enable-all' # enable-all, disable-seccomp-bpf, disable-all
# c.qt.environ = {} # Additional environment variables to set. Setting an environment variable to null/None will unset it.
# c.qt.force_platform = None # Force a Qt platform to use. This sets the `QT_QPA_PLATFORM` environment variable
# c.qt.force_platformtheme = None # Force a Qt platformtheme to use. This sets the `QT_QPA_PLATFORMTHEME`
# c.qt.workarounds.disable_accelerated_2d_canvas = 'always' # auto, always, never
# c.qt.workarounds.disable_accessibility = 'always' # auto, never

c.scrolling.bar = "when-searching"  # overlay, when-searching, never, always
c.scrolling.smooth = True

c.search.ignore_case = "smart"  # never, always, smart
c.search.incremental = True
c.search.wrap = True
c.search.wrap_messages = True  # Search hit TOP

# c.session.default_name = None # Name of the session to save by default. If this is set to null, the session which was last loaded is saved.
c.session.lazy_restore = True

# c.spellcheck.languages = [ 'en-US', 'tr-TR' ]

c.statusbar.padding = {
    "top": theme.DIM_T,
    "bottom": theme.DIM_T,
    "left": theme.DIM_T,
    "right": theme.DIM_T,
}
c.statusbar.position = "top"
c.statusbar.show = "always"  # in-mode, never, always
c.statusbar.widgets = [
    "keypress",
    "search_match",
    "url",
    "scroll",
    "history",
    "tabs",
    "progress",
]  # 'text:foo' for static text

c.tabs.background = True  # Open new tabs (middleclick/ctrl+click) in the background.
c.tabs.close_mouse_button = "right"  # right, middle, none
# c.tabs.close_mouse_button_on_bar = 'new-tab' # close pressed outside any tabs. new-tab, close-current, close-last, ignore
c.tabs.favicons.scale = 0.83
# c.tabs.favicons.show = 'always' # always, never, pinned
c.tabs.focus_stack_size = 30
c.tabs.indicator.padding = {
    "top": theme.DIM_T,
    "bottom": theme.DIM_T,
    "left": 0,
    "right": theme.DIM_T,
}
c.tabs.indicator.width = theme.DIM_T
# c.tabs.last_close = 'ignore' # ignore, blank, startpage, default-page, close
c.tabs.mode_on_change = "restore"  # mode when switching tabs. persists, restore, normal
# c.tabs.mousewheel_switching = True  # Switch between tabs using the mouse wheel.
# c.tabs.new_position.stacking = True # Stack related tabs on top of each other when opened consecutively.
# c.tabs.new_position.related = 'next'
c.tabs.new_position.unrelated = "last"  # last, first, next, prev
c.tabs.padding = {
    "top": theme.DIM_T - 1,
    "bottom": theme.DIM_T - 1,
    "left": 0,
    "right": 0,
}
# c.tabs.pinned.frozen = True ## Force pinned tabs to stay at fixed URL.
# c.tabs.pinned.shrink = True ## Shrink pinned tabs down to their contents.
c.tabs.position = "left"
c.tabs.select_on_remove = "last-used"  # orev, next, last-used
c.tabs.show = "always"  # never, switching
# c.tabs.show_switching_delay = 800 ## Duration (in milliseconds) to show the tab bar before hiding it when tabs.show is set to 'switching'.
# c.tabs.tabs_are_windows = False # Open new window for each tab
c.tabs.title.alignment = "left"
c.tabs.title.elide = "right"  # none, middle, left, right
c.tabs.title.format = "{relative_index}:{audio} {current_title}"
c.tabs.title.format_pinned = "{aligned_index}:{audio} {current_title}"
# c.tabs.tooltips = True
c.tabs.undo_stack_size = 120
c.tabs.width = "14%"
c.tabs.wrap = True

c.url.yank_ignored_parameters = [
    "ref",
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "utm_name",
]  # parameters to strip when yanking
c.url.start_pages = ["https://start.duckduckgo.com"]
c.url.default_page = "https://start.duckduckgo.com/"
c.url.open_base_url = True
c.url.searchengines = {
    "r": "https://www.reddit.com/search/?q={}",
    "x": "https://x.com/search?q={}&src=typed_query",
    "y": "https://www.youtube.com/results?search_query={}",
    "ym": "https://music.youtube.com/search?q={}",
    "np": "https://search.nixos.org/packages?channel=unstable&query={}",
    "no": "https://search.nixos.org/options?channel=unstable&query={}",
    "tt": "https://translate.google.com.tr/?sl=tr&tl=en&text={}&op=translate",
    "te": "https://translate.google.com.tr/?sl=en&tl=tr&text={}&op=translate",
    "g": "https://www.google.com/search?q={}",
    "DEFAULT": "https://duckduckgo.com/?q={}",
}

c.window.transparent = False
c.window.hide_decoration = False
c.window.title_format = "qute"

c.zoom.default = "100%"
c.zoom.levels = [
    "25%",
    "33%",
    "50%",
    "67%",
    "75%",
    "90%",
    "100%",
    "125%",
    "150%",
    "175%",
    "200%",
    "250%",
    "300%",
    "400%",
    "500%",
]


c.fonts.default_size = str(theme.FONT_SIZE_M) + "pt"
c.fonts.default_family = [theme.FONTS_SANS]
c.fonts.completion.category = "bold default_size default_family"
c.fonts.completion.entry = "default_size " + theme.FONTS_MONO
c.fonts.contextmenu = None
c.fonts.debug_console = "default_size default_family"
c.fonts.downloads = "default_size default_family"
c.fonts.hints = "bold default_size " + theme.FONTS_MONO
c.fonts.keyhint = "default_size " + theme.FONTS_MONO
c.fonts.messages.error = "default_size default_family"
c.fonts.messages.info = "default_size default_family"
c.fonts.messages.warning = "default_size default_family"
c.fonts.prompts = "default_size default_family"
c.fonts.statusbar = "default_size " + theme.FONTS_MONO
c.fonts.tabs.selected = "bold default_size default_family"
c.fonts.tabs.unselected = "default_size default_family"
c.fonts.tooltip = None

c.fonts.web.size.default = int(theme.FONT_SIZE_M * 4 / 3)
c.fonts.web.size.default_fixed = int(theme.FONT_SIZE_M * 4 / 3)
# c.fonts.web.size.minimum = 0
# c.fonts.web.size.minimum_logical = 6
c.fonts.web.family.cursive = theme.FONTS_SERIF
c.fonts.web.family.fantasy = theme.FONTS_SERIF
c.fonts.web.family.fixed = theme.FONTS_MONO
c.fonts.web.family.sans_serif = theme.FONTS_SANS
c.fonts.web.family.serif = theme.FONTS_SERIF
c.fonts.web.family.standard = theme.FONTS_SANS

c.colors.webpage.bg = ""  # Background color for webpages
c.colors.webpage.darkmode.enabled = False
c.colors.webpage.preferred_color_scheme = "dark" if theme.IS_DARK else "light"

c.colors.completion.category.bg = theme.COL_O
c.colors.completion.category.border.bottom = theme.COL_B
c.colors.completion.category.border.top = theme.COL_B
c.colors.completion.category.fg = theme.COL_F
c.colors.completion.even.bg = theme.COL_B
c.colors.completion.odd.bg = theme.COL_B
c.colors.completion.fg = theme.COL_M
c.colors.completion.item.selected.bg = theme.COL_O
c.colors.completion.item.selected.border.bottom = theme.COL_B
c.colors.completion.item.selected.border.top = theme.COL_B
c.colors.completion.item.selected.fg = theme.COL_M
c.colors.completion.item.selected.match.fg = theme.COL_F
c.colors.completion.match.fg = theme.COL_F
c.colors.completion.scrollbar.bg = theme.COL_B
c.colors.completion.scrollbar.fg = theme.COL_M

c.colors.contextmenu.disabled.bg = None
c.colors.contextmenu.disabled.fg = None
c.colors.contextmenu.menu.bg = None
c.colors.contextmenu.menu.fg = None
c.colors.contextmenu.selected.bg = None
c.colors.contextmenu.selected.fg = None

c.colors.downloads.bar.bg = theme.COL_O
c.colors.downloads.error.bg = theme.COL_S
c.colors.downloads.error.fg = theme.COL_B
c.colors.downloads.start.bg = theme.COL_O
c.colors.downloads.start.fg = theme.COL_S
c.colors.downloads.stop.bg = theme.COL_O
c.colors.downloads.stop.fg = theme.COL_P
c.colors.downloads.system.bg = "none"  # rgb, hsv, hsl, none
c.colors.downloads.system.fg = "none"

c.colors.hints.bg = theme.COL_B
c.colors.hints.fg = theme.COL_S
c.colors.hints.match.fg = theme.COL_F

c.colors.keyhint.bg = theme.COL_B
c.colors.keyhint.fg = theme.COL_S
c.colors.keyhint.suffix.fg = theme.COL_F

c.colors.messages.error.bg = theme.COL_O
c.colors.messages.error.border = theme.COL_O
c.colors.messages.error.fg = theme.COL_S

c.colors.messages.info.bg = theme.COL_O
c.colors.messages.info.border = theme.COL_O
c.colors.messages.info.fg = theme.COL_M

c.colors.messages.warning.bg = theme.COL_O
c.colors.messages.warning.border = theme.COL_O
c.colors.messages.warning.fg = theme.COL_P

c.colors.prompts.bg = theme.COL_B
c.colors.prompts.border = "none"
c.colors.prompts.fg = theme.COL_M
c.colors.prompts.selected.bg = theme.COL_O
c.colors.prompts.selected.fg = theme.COL_F

c.colors.statusbar.caret.bg = theme.COL_S
c.colors.statusbar.caret.fg = theme.COL_B
c.colors.statusbar.caret.selection.bg = theme.COL_S
c.colors.statusbar.caret.selection.fg = theme.COL_F
c.colors.statusbar.command.bg = theme.COL_B
c.colors.statusbar.command.fg = theme.COL_F
c.colors.statusbar.command.private.bg = theme.COL_B
c.colors.statusbar.command.private.fg = theme.COL_F
c.colors.statusbar.insert.bg = theme.COL_P
c.colors.statusbar.insert.fg = theme.COL_B
c.colors.statusbar.normal.bg = theme.COL_O
c.colors.statusbar.normal.fg = theme.COL_F
c.colors.statusbar.passthrough.bg = theme.COL_P
c.colors.statusbar.passthrough.fg = theme.COL_F
c.colors.statusbar.private.bg = theme.COL_P
c.colors.statusbar.private.fg = theme.COL_F
c.colors.statusbar.progress.bg = theme.COL_F
c.colors.statusbar.url.error.fg = theme.COL_S
c.colors.statusbar.url.fg = theme.COL_F
c.colors.statusbar.url.hover.fg = theme.COL_S
c.colors.statusbar.url.warn.fg = theme.COL_S
c.colors.statusbar.url.success.http.fg = theme.COL_P
c.colors.statusbar.url.success.https.fg = theme.COL_P

c.colors.tabs.bar.bg = theme.COL_O
c.colors.tabs.even.bg = theme.COL_O
c.colors.tabs.odd.bg = theme.COL_O
c.colors.tabs.even.fg = theme.COL_M
c.colors.tabs.odd.fg = theme.COL_M
c.colors.tabs.selected.even.bg = theme.COL_B
c.colors.tabs.selected.odd.bg = theme.COL_B
c.colors.tabs.selected.even.fg = theme.COL_F
c.colors.tabs.selected.odd.fg = theme.COL_F
c.colors.tabs.indicator.error = theme.COL_S
c.colors.tabs.indicator.start = theme.COL_P
c.colors.tabs.indicator.stop = theme.COL_O
c.colors.tabs.indicator.system = "none"  # rgb, hsv, hsl, none
c.colors.tabs.pinned.even.bg = theme.COL_O
c.colors.tabs.pinned.odd.bg = theme.COL_O
c.colors.tabs.pinned.even.fg = theme.COL_P
c.colors.tabs.pinned.odd.fg = theme.COL_P
c.colors.tabs.pinned.selected.even.bg = theme.COL_B
c.colors.tabs.pinned.selected.odd.bg = theme.COL_B
c.colors.tabs.pinned.selected.even.fg = theme.COL_F
c.colors.tabs.pinned.selected.odd.fg = theme.COL_F

c.colors.tooltip.bg = None
c.colors.tooltip.fg = None


# Bindings for normal mode
config.bind("'", "mode-enter jump_mark")
config.bind("+", "zoom-in")
config.bind("-", "zoom-out")
config.bind(".", "cmd-repeat-last")
config.bind("/", "cmd-set-text /")
config.bind(":", "cmd-set-text :")
config.bind(";I", "hint images tab")
config.bind(";O", "hint links fill :open -t -r {hint-url}")
config.bind(";R", "hint --rapid links window")
config.bind(";Y", "hint links yank-primary")
config.bind(";b", "hint all tab-bg")
config.bind(";d", "hint links download")
config.bind(";f", "hint all tab-fg")
config.bind(";h", "hint all hover")
config.bind(";i", "hint images")
config.bind(";o", "hint links fill :open {hint-url}")
config.bind(";r", "hint --rapid links tab-bg")
config.bind(";t", "hint inputs")
config.bind(";y", "hint links yank")
config.bind("<Alt-1>", "tab-focus 1")
config.bind("<Alt-2>", "tab-focus 2")
config.bind("<Alt-3>", "tab-focus 3")
config.bind("<Alt-4>", "tab-focus 4")
config.bind("<Alt-5>", "tab-focus 5")
config.bind("<Alt-6>", "tab-focus 6")
config.bind("<Alt-7>", "tab-focus 7")
config.bind("<Alt-8>", "tab-focus 8")
config.bind("<Alt-9>", "tab-focus -1")
config.bind("<Alt-m>", "tab-mute")
config.bind("<Ctrl-A>", "navigate increment")
config.bind("<Ctrl-Alt-p>", "print")
config.bind("<Ctrl-B>", "scroll-page 0 -1")
config.bind("<Ctrl-D>", "scroll-page 0 0.5")
config.bind("<Ctrl-F5>", "reload -f")
config.bind("<Ctrl-F>", "scroll-page 0 1")
config.bind("<Ctrl-N>", "open -w")
config.bind("<Ctrl-PgDown>", "tab-next")
config.bind("<Ctrl-PgUp>", "tab-prev")
config.bind("<Ctrl-Q>", "quit")
config.bind("<Ctrl-Return>", "selection-follow -t")
config.bind("<Ctrl-Shift-N>", "open -p")
config.bind("<Ctrl-Shift-T>", "undo")
config.bind("<Ctrl-Shift-Tab>", "nop")
config.bind("<Ctrl-Shift-W>", "close")
config.bind("<Ctrl-T>", "open -t")
config.bind("<Ctrl-Tab>", "tab-focus last")
config.bind("<Ctrl-U>", "scroll-page 0 -0.5")
config.bind("<Ctrl-V>", "mode-enter passthrough")
config.bind("<Ctrl-W>", "tab-close")
config.bind("<Ctrl-X>", "navigate decrement")
config.bind("<Ctrl-^>", "tab-focus last")
config.bind("<Ctrl-h>", "home")
config.bind("<Ctrl-p>", "tab-pin")
config.bind("<Ctrl-s>", "stop")
config.bind("<Escape>", "clear-keychain ;; search ;; fullscreen --leave")
config.bind("<F11>", "fullscreen")
config.bind("<F5>", "reload")
config.bind("<Return>", "selection-follow")
config.bind("<back>", "back")
config.bind("<forward>", "forward")
config.bind("=", "zoom")
config.bind("?", "cmd-set-text ?")
config.bind("@", "macro-run")
config.bind("B", "cmd-set-text -s :quickmark-load -t")
config.bind("D", "tab-close -o")
config.bind("F", "hint all tab")
config.bind("G", "scroll-to-perc")
config.bind("H", "back")
config.bind("J", "tab-next")
config.bind("K", "tab-prev")
config.bind("L", "forward")
config.bind("M", "bookmark-add")
config.bind("N", "search-prev")
config.bind("O", "cmd-set-text -s :open -t")
config.bind("PP", "open -t -- {primary}")
config.bind("Pp", "open -t -- {clipboard}")
config.bind("R", "reload -f")
config.bind("Sb", "bookmark-list --jump")
config.bind("Sh", "history")
config.bind("Sq", "bookmark-list")
config.bind("Ss", "set")
config.bind("T", "cmd-set-text -sr :tab-focus")
config.bind("U", "undo -w")
config.bind("V", "mode-enter caret ;; selection-toggle --line")
config.bind("ZQ", "quit")
config.bind("ZZ", "quit --save")
config.bind("[[", "navigate prev")
config.bind("]]", "navigate next")
config.bind("`", "mode-enter set_mark")
config.bind("ad", "download-cancel")
config.bind("b", "cmd-set-text -s :quickmark-load")
config.bind("cd", "download-clear")
config.bind("co", "tab-only")
config.bind("d", "tab-close")
config.bind("f", "hint")
config.bind("g$", "tab-focus -1")
config.bind("g0", "tab-focus 1")
config.bind("gB", "cmd-set-text -s :bookmark-load -t")
config.bind("gC", "tab-clone")
config.bind("gD", "tab-give")
config.bind("gJ", "tab-move +")
config.bind("gK", "tab-move -")
config.bind("gO", "cmd-set-text :open -t -r {url:pretty}")
config.bind("gU", "navigate up -t")
config.bind("g^", "tab-focus 1")
config.bind("ga", "open -t")
config.bind("gb", "cmd-set-text -s :bookmark-load")
config.bind("gd", "download")
config.bind("gf", "view-source")
config.bind("gg", "scroll-to-perc 0")
config.bind("gi", "hint inputs --first")
config.bind("gm", "tab-move")
config.bind("go", "cmd-set-text :open {url:pretty}")
config.bind("gt", "cmd-set-text -s :tab-select")
config.bind("gu", "navigate up")
config.bind("h", "scroll left")
config.bind("i", "mode-enter insert")
config.bind("j", "scroll down")
config.bind("k", "scroll up")
config.bind("l", "scroll right")
config.bind("m", "quickmark-save")
config.bind("n", "search-next")
config.bind("o", "cmd-set-text -s :open")
config.bind("pP", "open -- {primary}")
config.bind("pp", "open -- {clipboard}")
config.bind("q", "macro-record")
config.bind("r", "reload")
config.bind("sf", "save")
config.bind("sk", "cmd-set-text -s :bind")
config.bind("sl", "cmd-set-text -s :set -t")
config.bind("ss", "cmd-set-text -s :set")
config.bind(
    "tCH",
    "config-cycle -p -u *://*.{url:host}/* content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind(
    "tCh",
    "config-cycle -p -u *://{url:host}/* content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind(
    "tCu",
    "config-cycle -p -u {url} content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind("tIH", "config-cycle -p -u *://*.{url:host}/* content.images ;; reload")
config.bind("tIh", "config-cycle -p -u *://{url:host}/* content.images ;; reload")
config.bind("tIu", "config-cycle -p -u {url} content.images ;; reload")
config.bind("tPH", "config-cycle -p -u *://*.{url:host}/* content.plugins ;; reload")
config.bind("tPh", "config-cycle -p -u *://{url:host}/* content.plugins ;; reload")
config.bind("tPu", "config-cycle -p -u {url} content.plugins ;; reload")
config.bind(
    "tSH", "config-cycle -p -u *://*.{url:host}/* content.javascript.enabled ;; reload"
)
config.bind(
    "tSh", "config-cycle -p -u *://{url:host}/* content.javascript.enabled ;; reload"
)
config.bind("tSu", "config-cycle -p -u {url} content.javascript.enabled ;; reload")
config.bind(
    "tcH",
    "config-cycle -p -t -u *://*.{url:host}/* content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind(
    "tch",
    "config-cycle -p -t -u *://{url:host}/* content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind(
    "tcu",
    "config-cycle -p -t -u {url} content.cookies.accept all no-3rdparty never ;; reload",
)
config.bind("th", "back -t")
config.bind("tiH", "config-cycle -p -t -u *://*.{url:host}/* content.images ;; reload")
config.bind("tih", "config-cycle -p -t -u *://{url:host}/* content.images ;; reload")
config.bind("tiu", "config-cycle -p -t -u {url} content.images ;; reload")
config.bind("tl", "forward -t")
config.bind("tpH", "config-cycle -p -t -u *://*.{url:host}/* content.plugins ;; reload")
config.bind("tph", "config-cycle -p -t -u *://{url:host}/* content.plugins ;; reload")
config.bind("tpu", "config-cycle -p -t -u {url} content.plugins ;; reload")
config.bind(
    "tsH",
    "config-cycle -p -t -u *://*.{url:host}/* content.javascript.enabled ;; reload",
)
config.bind(
    "tsh", "config-cycle -p -t -u *://{url:host}/* content.javascript.enabled ;; reload"
)
config.bind("tsu", "config-cycle -p -t -u {url} content.javascript.enabled ;; reload")
config.bind("u", "undo")
config.bind("v", "mode-enter caret")
config.bind("wB", "cmd-set-text -s :bookmark-load -w")
config.bind("wIf", "devtools-focus")
config.bind("wIh", "devtools left")
config.bind("wIj", "devtools bottom")
config.bind("wIk", "devtools top")
config.bind("wIl", "devtools right")
config.bind("wIw", "devtools window")
config.bind("wO", "cmd-set-text :open -w {url:pretty}")
config.bind("wP", "open -w -- {primary}")
config.bind("wb", "cmd-set-text -s :quickmark-load -w")
config.bind("wf", "hint all window")
config.bind("wh", "back -w")
config.bind("wi", "devtools")
config.bind("wl", "forward -w")
config.bind("wo", "cmd-set-text -s :open -w")
config.bind("wp", "open -w -- {clipboard}")
config.bind("xO", "cmd-set-text :open -b -r {url:pretty}")
config.bind("xo", "cmd-set-text -s :open -b")
config.bind("yD", "yank domain -s")
config.bind("yM", "yank inline [{title}]({url:yank}) -s")
config.bind("yP", "yank pretty-url -s")
config.bind("yT", "yank title -s")
config.bind("yY", "yank -s")
config.bind("yd", "yank domain")
config.bind("ym", "yank inline [{title}]({url:yank})")
config.bind("yp", "yank pretty-url")
config.bind("yt", "yank title")
config.bind("yy", "yank")
config.bind("{{", "navigate prev -t")
config.bind("}}", "navigate next -t")

# Bindings for caret mode
config.bind("$", "move-to-end-of-line", mode="caret")
config.bind("0", "move-to-start-of-line", mode="caret")
config.bind("<Ctrl-Space>", "selection-drop", mode="caret")
config.bind("<Escape>", "mode-leave", mode="caret")
config.bind("<Return>", "yank selection", mode="caret")
config.bind("<Space>", "selection-toggle", mode="caret")
config.bind("G", "move-to-end-of-document", mode="caret")
config.bind("H", "scroll left", mode="caret")
config.bind("J", "scroll down", mode="caret")
config.bind("K", "scroll up", mode="caret")
config.bind("L", "scroll right", mode="caret")
config.bind("V", "selection-toggle --line", mode="caret")
config.bind("Y", "yank selection -s", mode="caret")
config.bind("[", "move-to-start-of-prev-block", mode="caret")
config.bind("]", "move-to-start-of-next-block", mode="caret")
config.bind("b", "move-to-prev-word", mode="caret")
config.bind("c", "mode-enter normal", mode="caret")
config.bind("e", "move-to-end-of-word", mode="caret")
config.bind("gg", "move-to-start-of-document", mode="caret")
config.bind("h", "move-to-prev-char", mode="caret")
config.bind("j", "move-to-next-line", mode="caret")
config.bind("k", "move-to-prev-line", mode="caret")
config.bind("l", "move-to-next-char", mode="caret")
config.bind("o", "selection-reverse", mode="caret")
config.bind("v", "selection-toggle", mode="caret")
config.bind("w", "move-to-next-word", mode="caret")
config.bind("y", "yank selection", mode="caret")
config.bind("{", "move-to-end-of-prev-block", mode="caret")
config.bind("}", "move-to-end-of-next-block", mode="caret")

# Bindings for command mode
config.bind("<Alt-B>", "rl-backward-word", mode="command")
config.bind("<Alt-Backspace>", "rl-backward-kill-word", mode="command")
config.bind("<Alt-D>", "rl-kill-word", mode="command")
config.bind("<Alt-F>", "rl-forward-word", mode="command")
config.bind("<Ctrl-?>", "rl-delete-char", mode="command")
config.bind("<Ctrl-A>", "rl-beginning-of-line", mode="command")
config.bind("<Ctrl-B>", "rl-backward-char", mode="command")
config.bind("<Ctrl-C>", "completion-item-yank", mode="command")
config.bind("<Ctrl-D>", "completion-item-del", mode="command")
config.bind("<Ctrl-E>", "rl-end-of-line", mode="command")
config.bind("<Ctrl-F>", "rl-forward-char", mode="command")
config.bind("<Ctrl-H>", "rl-backward-delete-char", mode="command")
config.bind("<Ctrl-K>", "rl-kill-line", mode="command")
config.bind("<Ctrl-N>", "command-history-next", mode="command")
config.bind("<Ctrl-P>", "command-history-prev", mode="command")
config.bind("<Ctrl-Return>", "command-accept --rapid", mode="command")
config.bind("<Ctrl-Shift-C>", "completion-item-yank --sel", mode="command")
config.bind("<Ctrl-Shift-Tab>", "completion-item-focus prev-category", mode="command")
config.bind("<Ctrl-Shift-W>", "rl-filename-rubout", mode="command")
config.bind("<Ctrl-Tab>", "completion-item-focus next-category", mode="command")
config.bind("<Ctrl-U>", "rl-unix-line-discard", mode="command")
config.bind("<Ctrl-W>", 'rl-rubout " "', mode="command")
config.bind("<Ctrl-Y>", "rl-yank", mode="command")
config.bind("<Down>", "completion-item-focus --history next", mode="command")
config.bind("<Escape>", "mode-leave", mode="command")
config.bind("<PgDown>", "completion-item-focus next-page", mode="command")
config.bind("<PgUp>", "completion-item-focus prev-page", mode="command")
config.bind("<Return>", "command-accept", mode="command")
config.bind("<Shift-Delete>", "completion-item-del", mode="command")
config.bind("<Shift-Tab>", "completion-item-focus prev", mode="command")
config.bind("<Tab>", "completion-item-focus next", mode="command")
config.bind("<Up>", "completion-item-focus --history prev", mode="command")

# Bindings for hint mode
config.bind("<Ctrl-B>", "hint all tab-bg", mode="hint")
config.bind("<Ctrl-F>", "hint links", mode="hint")
config.bind("<Ctrl-R>", "hint --rapid links tab-bg", mode="hint")
config.bind("<Escape>", "mode-leave", mode="hint")
config.bind("<Return>", "hint-follow", mode="hint")

# Bindings for insert mode
config.bind("<Ctrl-E>", "edit-text", mode="insert")
config.bind("<Escape>", "mode-leave", mode="insert")
config.bind("<Shift-Escape>", "fake-key <Escape>", mode="insert")
config.bind("<Shift-Ins>", "insert-text -- {primary}", mode="insert")

# Bindings for passthrough mode
config.bind("<Shift-Escape>", "mode-leave", mode="passthrough")

# Bindings for prompt mode
config.bind("<Alt-B>", "rl-backward-word", mode="prompt")
config.bind("<Alt-Backspace>", "rl-backward-kill-word", mode="prompt")
config.bind("<Alt-D>", "rl-kill-word", mode="prompt")
config.bind("<Alt-E>", "prompt-fileselect-external", mode="prompt")
config.bind("<Alt-F>", "rl-forward-word", mode="prompt")
config.bind("<Alt-Shift-Y>", "prompt-yank --sel", mode="prompt")
config.bind("<Alt-Y>", "prompt-yank", mode="prompt")
config.bind("<Ctrl-?>", "rl-delete-char", mode="prompt")
config.bind("<Ctrl-A>", "rl-beginning-of-line", mode="prompt")
config.bind("<Ctrl-B>", "rl-backward-char", mode="prompt")
config.bind("<Ctrl-E>", "rl-end-of-line", mode="prompt")
config.bind("<Ctrl-F>", "rl-forward-char", mode="prompt")
config.bind("<Ctrl-H>", "rl-backward-delete-char", mode="prompt")
config.bind("<Ctrl-K>", "rl-kill-line", mode="prompt")
config.bind("<Ctrl-P>", "prompt-open-download --pdfjs", mode="prompt")
config.bind("<Ctrl-Shift-W>", "rl-filename-rubout", mode="prompt")
config.bind("<Ctrl-U>", "rl-unix-line-discard", mode="prompt")
config.bind("<Ctrl-W>", 'rl-rubout " "', mode="prompt")
config.bind("<Ctrl-X>", "prompt-open-download", mode="prompt")
config.bind("<Ctrl-Y>", "rl-yank", mode="prompt")
config.bind("<Down>", "prompt-item-focus next", mode="prompt")
config.bind("<Escape>", "mode-leave", mode="prompt")
config.bind("<Return>", "prompt-accept", mode="prompt")
config.bind("<Shift-Tab>", "prompt-item-focus prev", mode="prompt")
config.bind("<Tab>", "prompt-item-focus next", mode="prompt")
config.bind("<Up>", "prompt-item-focus prev", mode="prompt")

# Bindings for register mode
config.bind("<Escape>", "mode-leave", mode="register")

# Bindings for yesno mode
config.bind("<Alt-Shift-Y>", "prompt-yank --sel", mode="yesno")
config.bind("<Alt-Y>", "prompt-yank", mode="yesno")
config.bind("<Escape>", "mode-leave", mode="yesno")
config.bind("<Return>", "prompt-accept", mode="yesno")
config.bind("N", "prompt-accept --save no", mode="yesno")
config.bind("Y", "prompt-accept --save yes", mode="yesno")
config.bind("n", "prompt-accept no", mode="yesno")
config.bind("y", "prompt-accept yes", mode="yesno")
