from __future__ import annotations

from dataclasses import dataclass
from html.parser import HTMLParser


@dataclass(frozen=True)
class ImageObservation:
    src: str
    alt_present: bool
    alt: str
    decorative: bool
    ambiguous: bool


class DocumentParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._hidden_depth = 0
        self._jsonld_depth = 0
        self._jsonld_parts: list[str] = []
        self.visible_parts: list[str] = []
        self.jsonld_blocks: list[str] = []
        self.images: list[ImageObservation] = []
        self.title = ""
        self._title_depth = 0
        self.links: list[str] = []
        self.meta: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_map = {key.casefold(): value or "" for key, value in attrs}
        lowered = tag.casefold()
        if lowered in {"script", "style", "noscript", "template"}:
            self._hidden_depth += 1
        if (
            lowered == "script"
            and attrs_map.get("type", "").casefold() == "application/ld+json"
        ):
            self._jsonld_depth += 1
            self._jsonld_parts = []
        if lowered == "title":
            self._title_depth += 1
        if lowered == "img":
            self.images.append(classify_image(attrs_map))
        if lowered == "a" and attrs_map.get("href"):
            self.links.append(attrs_map["href"])
        if lowered == "meta":
            key = attrs_map.get("name") or attrs_map.get("property")
            if key:
                self.meta[key.casefold()] = attrs_map.get("content", "")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        lowered = tag.casefold()
        if lowered == "script" and self._jsonld_depth:
            self.jsonld_blocks.append("".join(self._jsonld_parts).strip())
            self._jsonld_parts = []
            self._jsonld_depth -= 1
        if (
            lowered in {"script", "style", "noscript", "template"}
            and self._hidden_depth
        ):
            self._hidden_depth -= 1
        if lowered == "title" and self._title_depth:
            self._title_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._jsonld_depth:
            self._jsonld_parts.append(data)
        if self._title_depth:
            self.title += data
        if not self._hidden_depth:
            stripped = data.strip()
            if stripped:
                self.visible_parts.append(stripped)

    @property
    def visible_text(self) -> str:
        return " ".join(self.visible_parts)


def parse_document(source: str) -> DocumentParser:
    parser = DocumentParser()
    parser.feed(source)
    parser.close()
    return parser


def classify_image(attrs: dict[str, str]) -> ImageObservation:
    alt_present = "alt" in attrs
    alt = attrs.get("alt", "")
    role = attrs.get("role", "").casefold()
    aria_hidden = attrs.get("aria-hidden", "").casefold() == "true"
    deliberate_empty = alt_present and not alt.strip()
    decorative = role in {"presentation", "none"} or aria_hidden or deliberate_empty
    missing_alt = not alt_present
    return ImageObservation(
        src=attrs.get("src", ""),
        alt_present=alt_present,
        alt=alt,
        decorative=decorative,
        ambiguous=missing_alt and not decorative,
    )
