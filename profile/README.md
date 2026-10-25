# Deckyard - community decks for Jennifer

Deckyard is a home for **decks** - libraries for the
[Jennifer](https://github.com/jennifer-language/jennifer) language - that are
maintained by the community. It is **not part of the Jennifer project**: the
project ships the language and its standard library, and Deckyard looks after
the decks around it.

Every deck here has a named maintainer, a test suite, and documentation that CI
checks against the code. They all share one CI layer, so a fix to how decks are
built and checked reaches every deck at once.

## Decks

| Deck | What it does |
|---|---|
| [`@deckyard/bioinformatics`](https://github.com/deckyard/deck-bioinformatics) | Sequence manipulation for DNA, RNA and protein |
| [`@deckyard/d64`](https://github.com/deckyard/deck-d64) | Read, write, create and format Commodore 1541 D64 disk images |
| [`@deckyard/forensicgenetics`](https://github.com/deckyard/deck-forensicgenetics) | STR match probabilities, kinship and paternity likelihood ratios, pedigrees, mtDNA / Y-STR lineage markers |
| [`@deckyard/geo`](https://github.com/deckyard/deck-geo) | GPX, KML, KMZ, GeoJSON and GML over one point model, with geodesy, track statistics, geohashes and map tiles |
| [`@deckyard/mitoleaf`](https://github.com/deckyard/deck-mitoleaf) | The mitoLEAF mitochondrial phylogeny: haplogroup tree and nearest-haplogroup lookup |
| [`@deckyard/mp3`](https://github.com/deckyard/deck-mp3) | ID3v2.2/2.3/2.4 and ID3v1.1 tags, artwork, MPEG frame and VBR analysis, M3U/M3U8 playlists |
| [`@deckyard/ngs`](https://github.com/deckyard/deck-ngs) | Streaming NGS file formats, read QC, interval arithmetic and pipeline orchestration |
| [`@deckyard/routeros`](https://github.com/deckyard/deck-routeros) | A friendly layer over the MikroTik RouterOS API |
| [`@deckyard/sheets`](https://github.com/deckyard/deck-sheets) | ODS, XLSX and Gnumeric over one cell model, with a CSV bridge |
| [`@deckyard/steam`](https://github.com/deckyard/deck-steam) | A friendly layer over Valve's Steam Web API |
| [`@deckyard/strider`](https://github.com/deckyard/deck-strider-frequency-converter) | STRidER allele-frequency tables into a `forensicgenetics` frequency database |
| [`@deckyard/tmdb`](https://github.com/deckyard/deck-tmdb) | A typed client for The Movie Database |

Each deck's README links its documentation and says which Jennifer version it
needs.

## Using a deck

```sh
jvc add @deckyard/geo
```

```jennifer
import "@deckyard/geo/" as geo;
```

## Getting involved

Every deck welcomes co-maintainers, and some are looking for one - see the
`help wanted` label. Fixes, tests and documentation are welcome everywhere.
[CONTRIBUTING.md](https://github.com/deckyard/.github/blob/main/CONTRIBUTING.md)
explains how a deck is maintained, how to propose a new one, and what happens
to a deck that loses its maintainer.

Report a security problem privately through the deck's **Security** tab, not as
a public issue.
