#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: exec

/**
 * Render the GitHub social preview of a deck: a 1280x640 PNG with the
 * deck's name and the description from its manifest beside a logo. The
 * scope picks the card:
 *
 *   @deckyard   the Deckyard logo on the left, text on the right, navy
 *   @jennifer   text on the left, the Jennifer monogram on the right, ink
 *
 * Other scopes are skipped.
 *
 *   jennifer run tools/social-preview.j                  # every deck
 *   jennifer run tools/social-preview.j ../geo ../gotify # these decks
 *   jennifer run tools/social-preview.j --out /tmp/p ../geo
 *
 * With no deck given it walks the directories beside deckyard-org. Each
 * deck gets `<out>/<repo>.svg` and `<out>/<repo>.png` (default
 * `deckyard-org/previews`), named after the repository its homepage URL
 * points to. GitHub has no API for social previews: upload each PNG under
 * the repository's Settings > General > Social preview; the script prints
 * the link.
 *
 * The Deckyard logo is `profile/deckyard.svg`; the Jennifer monogram is
 * read from a jennifer-lang checkout beside the decks
 * (`../jennifer-lang/site/logo/jennifer.svg`), or from `--jennifer-logo`.
 *
 * Text is set in DejaVu Sans, measured with the `font` module from the
 * files fontconfig names, so the SVG renderer (`rsvg-convert`, which also
 * asks fontconfig) draws what was measured. Needs `fc-match` and
 * `rsvg-convert`.
 */
use fs;
use io;
use os;
use strings;
use convert;
use toml;
use json;
use yaml;
use maps;
import "font.j" as font;

# The card, in pixels.
def const WIDTH as int init 1280;
def const HEIGHT as int init 640;

# The margin, the logo's size, and the text column's width; the column
# starts beside the logo, on whichever side the brand puts it.
def const MARGIN as int init 96;
def const LOGO_SIZE as int init 352;
def const TEXT_WIDTH as int init 656;

# Type sizes: the name shrinks from the first to the second to fit one line;
# the description from the first to the second to fit MAX_LINES.
def const NAME_SIZE as int init 104;
def const NAME_MIN as int init 64;
def const SCOPE_SIZE as int init 36;
def const TEXT_SIZE as int init 36;
def const TEXT_MIN as int init 26;
def const MAX_LINES as int init 5;

/** Two DejaVu Sans faces, for measuring. */
def struct Faces {
    regular as font.Font,
    bold as font.Font
};

/**
 * How a scope's cards look.
 *
 * @field scope {string} e.g. `@deckyard`
 * @field org {string} the GitHub organisation of its repositories, when a manifest names none
 * @field logo {string} the logo's drawing, its root element's content
 * @field viewBox {string} the logo's viewBox
 * @field background {string} the card's colour
 * @field text {string} the name's and the description's colour
 * @field muted {string} the scope's colour
 * @field accent {string} the rule's colour
 * @field logoLeft {bool} the logo on the left, the text on the right
 */
def struct Brand {
    scope as string,
    org as string,
    logo as string,
    viewBox as string,
    background as string,
    text as string,
    muted as string,
    accent as string,
    logoLeft as bool
};

/** What one card shows, and where it goes. */
def struct Card {
    dir as string,
    scope as string,
    name as string,
    description as string,
    org as string,
    repo as string
};

/**
 * Stop with a message.
 *
 * @param message {string} what went wrong
 */
func fail(message as string) {
    throw Error{kind: "social-preview", message: "social-preview: " + $message};
}

/**
 * The file fontconfig chooses for a pattern.
 *
 * @param pattern {string} e.g. `DejaVu Sans:bold`
 * @return {string} the font file
 */
func fontFile(pattern as string) {
    def r as os.Result init os.run(["fc-match", "-f", '%{file}', $pattern]);
    def path as string init strings.trim($r.stdout);
    if ($r.exitCode != 0 or $path == "") {
        fail("fc-match found no font for " + $pattern);
    }
    if (not strings.contains(strings.lower($path), "dejavu")) {
        fail("fontconfig maps " + $pattern + " to " + $path + ", not DejaVu Sans; install it");
    }
    return $path;
}

/**
 * How wide a text is when set in a face at a size.
 *
 * @param f {font.Font} the face
 * @param text {string} the text
 * @param size {int} the size in pixels
 * @return {float} the width in pixels
 */
func widthOf(f as font.Font, text as string, size as int) {
    def cps as list of int init [];
    for (def ch in strings.chars($text)) {
        $cps[] = convert.toCodepoint($ch);
    }
    def units as int init 0;
    for (def adv in font.advances($f, font.glyphIds($f, $cps))) {
        $units = $units + $adv;
    }
    return $units * $size / font.unitsPerEm($f);
}

/**
 * Break a text into lines no wider than `limit`, at spaces.
 *
 * @param f {font.Font} the face
 * @param text {string} the text
 * @param size {int} the size in pixels
 * @param limit {int} the widest line in pixels
 * @return {list of string} the lines
 */
func wrap(f as font.Font, text as string, size as int, limit as int) {
    def lines as list of string init [];
    def current as string init "";
    for (def word in strings.split(strings.trim($text), " ")) {
        if ($word == "") {
            continue;
        }
        def candidate as string init $word;
        if ($current != "") {
            $candidate = $current + " " + $word;
        }
        if ($current != "" and widthOf($f, $candidate, $size) > $limit) {
            $lines[] = $current;
            $current = $word;
        } else {
            $current = $candidate;
        }
    }
    if ($current != "") {
        $lines[] = $current;
    }
    return $lines;
}

/**
 * Escape text for an SVG text node.
 *
 * @param text {string} the text
 * @return {string} the escaped text
 */
func escaped(text as string) {
    return strings.replace(
        strings.replace(strings.replace($text, "&", "&amp;"), "<", "&lt;"),
        ">",
        "&gt;");
}

/**
 * An SVG `<text>` element.
 *
 * @param x {int} its left edge
 * @param y {int} its baseline
 * @param size {int} the font size
 * @param colour {string} the fill
 * @param bold {bool} bold rather than regular
 * @param content {string} the text, not yet escaped
 * @return {string} the element
 */
func textAt(x as int, y as int, size as int, colour as string, bold as bool, content as string) {
    def weight as string init "";
    if ($bold) {
        $weight = ' font-weight="bold"';
    }
    return '<text x="' + convert.toString($x) + '" y="' + convert.toString($y) + '" font-size="' +
        convert.toString($size) + '"' + $weight + ' fill="' + $colour + '">' + escaped($content) +
        "</text>";
}

/**
 * The card's SVG.
 *
 * @param faces {Faces} the faces, for measuring
 * @param b {Brand} how the card looks
 * @param c {Card} the deck
 * @return {string} the SVG document
 */
func render(faces as Faces, b as Brand, c as Card) {
    def nameSize as int init NAME_SIZE;
    while ($nameSize > NAME_MIN and widthOf($faces.bold, $c.name, $nameSize) > TEXT_WIDTH) {
        $nameSize = $nameSize - 2;
    }
    def textSize as int init TEXT_SIZE;
    def lines as list of string init wrap($faces.regular, $c.description, $textSize, TEXT_WIDTH);
    while ($textSize > TEXT_MIN and len($lines) > MAX_LINES) {
        $textSize = $textSize - 1;
        $lines = wrap($faces.regular, $c.description, $textSize, TEXT_WIDTH);
    }
    if (len($lines) > MAX_LINES) {
        fail($c.dir + ": the description needs more than " + convert.toString(MAX_LINES) +
            " lines; shorten it");
    }
    def logoX as int init MARGIN;
    def textX as int init MARGIN + LOGO_SIZE + 80;
    if (not $b.logoLeft) {
        $textX = MARGIN;
        $logoX = WIDTH - MARGIN - LOGO_SIZE;
    }
    def lineHeight as int init convert.toInt($textSize * 3 / 2);
    def gap as int init 40;
    # The block: scope, name, an accent rule, the description. Centred
    # vertically; y values are baselines.
    def blockHeight as int init SCOPE_SIZE + 16 + $nameSize + $gap + 6 + $gap +
        len($lines) * $lineHeight;
    def y as int init convert.toInt((HEIGHT - $blockHeight) / 2) + SCOPE_SIZE;
    def out as list of string init [];
    $out[] = '<svg xmlns="http://www.w3.org/2000/svg" width="' + convert.toString(WIDTH) +
        '" height="' + convert.toString(HEIGHT) + '" viewBox="0 0 ' + convert.toString(WIDTH) +
        " " + convert.toString(HEIGHT) + '">';
    $out[] = '<rect width="100%" height="100%" fill="' + $b.background + '"/>';
    $out[] = '<svg x="' + convert.toString($logoX) + '" y="' +
        convert.toString(convert.toInt((HEIGHT - LOGO_SIZE) / 2)) + '" width="' +
        convert.toString(LOGO_SIZE) + '" height="' + convert.toString(LOGO_SIZE) + '" viewBox="' +
        $b.viewBox + '">' + $b.logo + "</svg>";
    $out[] = '<g font-family="DejaVu Sans">';
    $out[] = textAt($textX, $y, SCOPE_SIZE, $b.muted, false, $c.scope + "/");
    $y = $y + 16 + $nameSize;
    $out[] = textAt($textX, $y, $nameSize, $b.text, true, $c.name);
    $y = $y + $gap;
    $out[] = '<rect x="' + convert.toString($textX) + '" y="' + convert.toString($y) +
        '" width="96" height="6" rx="3" fill="' + $b.accent + '"/>';
    $y = $y + 6 + $gap;
    for (def line in $lines) {
        $y = $y + $lineHeight;
        $out[] = textAt(
            $textX,
            $y - convert.toInt($lineHeight / 4),
            $textSize,
            $b.text,
            false,
            $line);
    }
    $out[] = "</g>";
    $out[] = "</svg>";
    return strings.join($out, "\n") + "\n";
}

/**
 * A brand whose logo is an SVG file: its drawing (what sits inside the root
 * `<svg>` element) and its viewBox.
 *
 * @param b {Brand} the brand, without its logo
 * @param path {string} the logo file
 * @return {Brand} the brand with its logo
 */
func withLogo(b as Brand, path as string) {
    if (not fs.exists($path)) {
        fail("no logo for " + $b.scope + " at " + $path);
    }
    def svg as string init fs.readString($path);
    def start as int init strings.indexOf($svg, "<svg");
    def open as int init strings.indexOf($svg, ">", $start);
    def close as int init strings.lastIndexOf($svg, "</svg>");
    if ($start < 0 or $open < 0 or $close < $open) {
        fail($path + " is not an SVG document");
    }
    def tag as string init $svg[$start..$open];
    def at as int init strings.indexOf($tag, 'viewBox="');
    if ($at < 0) {
        fail($path + " has no viewBox");
    }
    def rest as string init $tag[$at + 9..];
    def out as Brand init $b;
    $out.viewBox = $rest[..strings.indexOf($rest, '"')];
    $out.logo = $svg[$open + 1..$close];
    return $out;
}

/**
 * The name, description and homepage from a deck's manifest, whichever of
 * `deck.toml`, `deck.yaml`, `deck.yml` or `deck.json` it has; an empty map
 * when it has none.
 *
 * @param dir {string} the deck's directory
 * @return {map of string to string} `name`, `description`, `homepage`; a missing one is ""
 */
func manifestOf(dir as string) {
    def out as map of string to string init {};
    def keys as map of string to string init {
        "name": "/package/name",
        "description": "/package/description",
        "homepage": "/package/urls/homepage"
    };
    if (fs.exists($dir + "/deck.toml")) {
        def m as toml.Value init toml.decode(fs.readString($dir + "/deck.toml"));
        for (def k in $keys) {
            $out[$k] = "";
            if (toml.typeOf($m, $keys[$k]) == "string") {
                $out[$k] = toml.asString($m, $keys[$k]);
            }
        }
        return $out;
    }
    for (def file in ["deck.yaml", "deck.yml"]) {
        if (fs.exists($dir + "/" + $file)) {
            def m as yaml.Value init yaml.decode(fs.readString($dir + "/" + $file));
            for (def k in $keys) {
                $out[$k] = "";
                if (yaml.typeOf($m, $keys[$k]) == "string") {
                    $out[$k] = yaml.asString($m, $keys[$k]);
                }
            }
            return $out;
        }
    }
    if (fs.exists($dir + "/deck.json")) {
        def m as json.Value init json.decode(fs.readString($dir + "/deck.json"));
        for (def k in $keys) {
            $out[$k] = "";
            if (json.typeOf($m, $keys[$k]) == "string") {
                $out[$k] = json.asString($m, $keys[$k]);
            }
        }
    }
    return $out;
}

/**
 * Read a deck's card from its manifest. A directory with no manifest, no
 * description, or a scope without a brand gives a card with an empty name.
 *
 * @param dir {string} the deck's directory
 * @param brands {map of string to Brand} the brands, by scope
 * @return {Card} the card
 */
func cardOf(dir as string, brands as map of string to Brand) {
    def none as Card init Card{dir: $dir, scope: "", name: "", description: "", org: "", repo: ""};
    def m as map of string to string init manifestOf($dir);
    if (not maps.has($m, "name") or $m["description"] == "") {
        return $none;
    }
    def full as string init $m["name"];
    def slash as int init strings.indexOf($full, "/");
    if ($slash < 1 or not maps.has($brands, $full[..$slash])) {
        return $none;
    }
    def scope as string init $full[..$slash];
    def name as string init $full[$slash + 1..];
    def org as string init $brands[$scope].org;
    def repo as string init "deck-" + $name;
    # https://github.com/<org>/<repo>, the repository the card is uploaded to.
    def home as string init $m["homepage"];
    if (strings.startsWith($home, "https://github.com/")) {
        def parts as list of string init strings.split($home[len("https://github.com/")..], "/");
        if (len($parts) >= 2 and $parts[0] != "" and $parts[1] != "") {
            $org = $parts[0];
            $repo = $parts[1];
        }
    }
    return Card{
        dir: $dir,
        scope: $scope,
        name: $name,
        description: $m["description"],
        org: $org,
        repo: $repo
    };
}

# --- main ---------------------------------------------------------------------

def here as string init ".";
def scriptPath as string init os.ARGS[0];
if (strings.contains($scriptPath, "/")) {
    $here = $scriptPath[..strings.lastIndexOf($scriptPath, "/")];
}
def orgDir as string init $here + "/..";
if ($here == "tools") {
    $orgDir = ".";
} elseif (strings.endsWith($here, "/tools")) {
    $orgDir = $here[..len($here) - 6];
}
def outDir as string init $orgDir + "/previews";
def jenniferLogo as string init $orgDir + "/../../jennifer-lang/site/logo/jennifer.svg";
def decks as list of string init [];
def i as int init 1;
while ($i < len(os.ARGS)) {
    def arg as string init os.ARGS[$i];
    if (($arg == "--out" or $arg == "--jennifer-logo") and $i + 1 < len(os.ARGS)) {
        if ($arg == "--out") {
            $outDir = os.ARGS[$i + 1];
        } else {
            $jenniferLogo = os.ARGS[$i + 1];
        }
        $i = $i + 2;
    } else {
        $decks[] = $arg;
        $i = $i + 1;
    }
}
def explicit as bool init len($decks) > 0;
if (not $explicit) {
    for (def entry in fs.list($orgDir + "/..")) {
        if (fs.isDir($orgDir + "/../" + $entry)) {
            $decks[] = $orgDir + "/../" + $entry;
        }
    }
}

# The palettes are the logos' own: Deckyard's navy, paper and orange
# (profile/deckyard.svg); Jennifer's ink, paper and coral, with the
# monogram's aubergine tile standing out against the ink.
def brands as map of string to Brand init {
    "@deckyard": withLogo(
        Brand{
            scope: "@deckyard",
            org: "deckyard",
            logo: "",
            viewBox: "",
            background: "#0e1f36",
            text: "#f4f1ea",
            muted: "#9fb0c8",
            accent: "#ff7a45",
            logoLeft: true
        },
        $orgDir + "/profile/deckyard.svg"),
    "@jennifer": withLogo(
        Brand{
            scope: "@jennifer",
            org: "jennifer-language",
            logo: "",
            viewBox: "",
            background: "#241c29",
            text: "#f2ece6",
            muted: "#b3a5ba",
            accent: "#ec5c4b",
            logoLeft: false
        },
        $jenniferLogo)
};
def faces as Faces init Faces{
    regular: font.open(fontFile("DejaVu Sans")),
    bold: font.open(fontFile("DejaVu Sans:bold"))
};
fs.mkdirAll($outDir);
def made as int init 0;
for (def dir in $decks) {
    def c as Card init cardOf($dir, $brands);
    if ($c.name == "") {
        if ($explicit) {
            io.eprintf("skipped %s: no @deckyard or @jennifer manifest with a description\n", $dir);
        }
        continue;
    }
    def svgPath as string init $outDir + "/" + $c.repo + ".svg";
    def pngPath as string init $outDir + "/" + $c.repo + ".png";
    fs.writeString($svgPath, render($faces, $brands[$c.scope], $c));
    def r as os.Result init os.run([
        "rsvg-convert",
        "-w",
        convert.toString(WIDTH),
        "-h",
        convert.toString(HEIGHT),
        "-o",
        $pngPath,
        $svgPath
    ]);
    if ($r.exitCode != 0) {
        fail("rsvg-convert failed for " + $svgPath + ": " + strings.trim($r.stderr));
    }
    io.printf("%s  upload at https://github.com/%s/%s/settings\n", $pngPath, $c.org, $c.repo);
    $made = $made + 1;
}
io.printf("%d preview(s) in %s\n", $made, $outDir);
