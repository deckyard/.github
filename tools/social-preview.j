#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.25.0
# pragma-jennifer-capability: exec

/**
 * Render the GitHub social preview of Deckyard decks: a 1280x640 PNG with
 * the Deckyard logo on the left and, on the right, the deck's name and the
 * description from its manifest.
 *
 *   jennifer run tools/social-preview.j                  # every @deckyard deck
 *   jennifer run tools/social-preview.j ../geo ../git    # these decks
 *   jennifer run tools/social-preview.j --out /tmp/p ../geo
 *
 * With no deck given it walks the directories beside deckyard-org. Each
 * deck gets `<out>/<repo>.svg` and `<out>/<repo>.png` (default
 * `deckyard-org/previews`), named after the repository its homepage URL
 * points to. GitHub has no API for social previews: upload each PNG under
 * the repository's Settings > General > Social preview; the script prints
 * the link.
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

# The text column: from TEXT_X to WIDTH - MARGIN.
def const MARGIN as int init 96;
def const TEXT_X as int init 528;
def const TEXT_WIDTH as int init 656;

# The logo's colours (profile/deckyard.svg).
def const NAVY as string init "#0e1f36";
def const PAPER as string init "#f4f1ea";
def const ORANGE as string init "#ff7a45";
def const MUTED as string init "#9fb0c8";

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

/** What one card shows, and where it goes. */
def struct Card {
    dir as string,
    scope as string,
    name as string,
    description as string,
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
 * The card's SVG.
 *
 * @param faces {Faces} the faces, for measuring
 * @param c {Card} the deck
 * @param logo {string} the logo's SVG, its root element's content
 * @return {string} the SVG document
 */
func render(faces as Faces, c as Card, logo as string) {
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
    def lineHeight as int init convert.toInt($textSize * 3 / 2);
    def gap as int init 40;
    # The block: scope, name, an accent rule, the description. Centred
    # vertically; y values are baselines.
    def blockHeight as int init SCOPE_SIZE + 16 + $nameSize + $gap + 6 + $gap +
        len($lines) * $lineHeight;
    def top as int init convert.toInt((HEIGHT - $blockHeight) / 2);
    def y as int init $top + SCOPE_SIZE;
    def out as list of string init [];
    $out[] = '<svg xmlns="http://www.w3.org/2000/svg" width="' + convert.toString(WIDTH) +
        '" height="' +
        convert.toString(HEIGHT) + '" viewBox="0 0 ' + convert.toString(WIDTH) + " " +
        convert.toString(HEIGHT) + '">';
    $out[] = '<rect width="100%" height="100%" fill="' + NAVY + '"/>';
    # The logo: its 256x256 viewBox scaled to 352 px, centred in the left part.
    $out[] = '<svg x="' + convert.toString(MARGIN) +
        '" y="144" width="352" height="352" viewBox="0 0 256 256">' + $logo + "</svg>";
    $out[] = '<g font-family="DejaVu Sans">';
    $out[] = '<text x="' + convert.toString(TEXT_X) + '" y="' + convert.toString($y) +
        '" font-size="' +
        convert.toString(SCOPE_SIZE) + '" fill="' + MUTED + '">' + escaped($c.scope) + "/</text>";
    $y = $y + 16 + $nameSize;
    $out[] = '<text x="' + convert.toString(TEXT_X) + '" y="' + convert.toString($y) +
        '" font-size="' +
        convert.toString($nameSize) + '" font-weight="bold" fill="' + PAPER + '">' +
        escaped($c.name) + "</text>";
    $y = $y + $gap;
    $out[] = '<rect x="' + convert.toString(TEXT_X) + '" y="' + convert.toString($y) +
        '" width="96" height="6" rx="3" fill="' + ORANGE + '"/>';
    $y = $y + 6 + $gap;
    for (def line in $lines) {
        $y = $y + $lineHeight;
        $out[] = '<text x="' + convert.toString(TEXT_X) + '" y="' +
            convert.toString($y - $lineHeight / 4) + '" font-size="' +
            convert.toString($textSize) + '" fill="' + PAPER + '">' + escaped($line) + "</text>";
    }
    $out[] = "</g>";
    $out[] = "</svg>";
    return strings.join($out, "\n") + "\n";
}

/**
 * The logo's drawing: what sits inside its root `<svg>` element.
 *
 * @param path {string} the logo file
 * @return {string} the drawing
 */
func logoBody(path as string) {
    def svg as string init fs.readString($path);
    def open as int init strings.indexOf($svg, ">", strings.indexOf($svg, "<svg"));
    def close as int init strings.lastIndexOf($svg, "</svg>");
    if ($open < 0 or $close < $open) {
        fail($path + " is not an SVG document");
    }
    return $svg[$open + 1..$close];
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
 * Read a deck's card from its manifest. A deck outside the Deckyard scope,
 * or a directory with no manifest, gives a card with an empty name.
 *
 * @param dir {string} the deck's directory
 * @return {Card} the card
 */
func cardOf(dir as string) {
    def none as Card init Card{dir: $dir, scope: "", name: "", description: "", repo: ""};
    def m as map of string to string init manifestOf($dir);
    if (not maps.has($m, "name") or not strings.startsWith($m["name"], "@deckyard/") or
        $m["description"] == "") {
        return $none;
    }
    def full as string init $m["name"];
    def slash as int init strings.indexOf($full, "/");
    def repo as string init "deck-" + $full[$slash + 1..];
    if (strings.startsWith($m["homepage"], "https://github.com/deckyard/")) {
        $repo = $m["homepage"][strings.lastIndexOf($m["homepage"], "/") + 1..];
    }
    return Card{
        dir: $dir,
        scope: $full[..$slash],
        name: $full[$slash + 1..],
        description: $m["description"],
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
def decks as list of string init [];
def i as int init 1;
while ($i < len(os.ARGS)) {
    if (os.ARGS[$i] == "--out" and $i + 1 < len(os.ARGS)) {
        $outDir = os.ARGS[$i + 1];
        $i = $i + 2;
    } else {
        $decks[] = os.ARGS[$i];
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

def faces as Faces init Faces{
    regular: font.open(fontFile("DejaVu Sans")),
    bold: font.open(fontFile("DejaVu Sans:bold"))
};
def logo as string init logoBody($orgDir + "/profile/deckyard.svg");
fs.mkdirAll($outDir);
def made as int init 0;
for (def dir in $decks) {
    def c as Card init cardOf($dir);
    if ($c.name == "") {
        if ($explicit) {
            io.eprintf("skipped %s: no @deckyard deck.toml\n", $dir);
        }
        continue;
    }
    def svgPath as string init $outDir + "/" + $c.repo + ".svg";
    def pngPath as string init $outDir + "/" + $c.repo + ".png";
    fs.writeString($svgPath, render($faces, $c, $logo));
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
    io.printf("%s  upload at https://github.com/deckyard/%s/settings\n", $pngPath, $c.repo);
    $made = $made + 1;
}
io.printf("%d preview(s) in %s\n", $made, $outDir);
