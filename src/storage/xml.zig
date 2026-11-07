// From gcp.zig src/storage/xml.zig at eae944c: its reader and tests. Blob Storage's own here: a leading byte order mark skipped, and attributes kept; the multipart writer and Cloud Storage's error reader went.
//! The little XML Blob Storage speaks: `EnumerationResults`, a listing's
//! answer, and `Error`, a refusal's body. Every body production sends
//! begins with a UTF-8 byte order mark (EF BB BF), which Azurite's never
//! do; the reader skips one.
//!
//! The reader is strict and small. It keeps elements, their text and their
//! attributes, drops namespace prefixes from element names, and decodes the
//! five named entities and numeric references. It refuses a document type
//! declaration outright, so no entity is ever defined, let alone expanded,
//! and it refuses nesting past `max_depth`. Anything else it does not
//! understand is `error.InvalidResponse`, never a guess.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{ InvalidResponse, OutOfMemory };

/// How many levels of elements a document may nest, root included: far
/// more than any document Blob Storage sends.
pub const max_depth = 16;

/// UTF-8's byte order mark, which production writes before every body.
pub const bom = "\xef\xbb\xbf";

/// One attribute, its value with references decoded.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// One element: its local name, the text directly inside it, its
/// attributes and its child elements in order.
pub const Element = struct {
    /// Without any namespace prefix: `Name` for `x:Name`.
    name: []const u8,
    /// Every piece of text directly inside, joined, entities decoded.
    text: []const u8,
    attributes: []const Attribute = &.{},
    children: []const Element,

    /// The first child named `name`, or null.
    pub fn child(self: Element, name: []const u8) ?Element {
        for (self.children) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The text of the first child named `name`, or null.
    pub fn childText(self: Element, name: []const u8) ?[]const u8 {
        return if (self.child(name)) |c| c.text else null;
    }

    /// The value of the attribute named `name`, or null.
    pub fn attribute(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

/// The document's root element. Everything returned lives in `arena`.
pub fn parse(arena: Allocator, body: []const u8) DecodeError!Element {
    const text = if (std.mem.startsWith(u8, body, bom)) body[bom.len..] else body;
    var p: Parser = .{ .arena = arena, .body = text };
    return p.document();
}

const Parser = struct {
    arena: Allocator,
    body: []const u8,
    pos: usize = 0,

    fn document(p: *Parser) DecodeError!Element {
        try p.skipMisc();
        if (!p.startsWith("<") or p.startsWith("</")) return error.InvalidResponse;
        const root = try p.element(0);
        // After the root only whitespace, comments and instructions.
        try p.skipMisc();
        if (p.pos != p.body.len) return error.InvalidResponse;
        return root;
    }

    /// Whitespace, the declaration, processing instructions and comments,
    /// in any order. A document type declaration is refused: it is the
    /// only way to define an entity, and nothing here needs one.
    fn skipMisc(p: *Parser) DecodeError!void {
        while (true) {
            p.skipSpace();
            if (p.startsWith("<?")) {
                p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 2, "?>") orelse return error.InvalidResponse) + 2;
            } else if (p.startsWith("<!--")) {
                try p.skipComment();
            } else if (p.startsWith("<!")) {
                return error.InvalidResponse;
            } else {
                return;
            }
        }
    }

    fn skipComment(p: *Parser) DecodeError!void {
        p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 4, "-->") orelse return error.InvalidResponse) + 3;
    }

    /// One element, from its `<` to the end of its closing tag.
    fn element(p: *Parser, depth: usize) DecodeError!Element {
        if (depth >= max_depth) return error.InvalidResponse;
        p.pos += 1; // '<'
        const qualified = p.name();
        const local = localName(qualified) orelse return error.InvalidResponse;
        var attributes: std.ArrayList(Attribute) = .empty;
        const self_closing = try p.readAttributes(&attributes);
        const attrs = try attributes.toOwnedSlice(p.arena);
        if (self_closing) return .{ .name = local, .text = "", .attributes = attrs, .children = &.{} };

        var text: std.ArrayList(u8) = .empty;
        var children: std.ArrayList(Element) = .empty;
        while (!try p.contentItem(depth, qualified, &text, &children)) {}
        return .{
            .name = local,
            .text = try text.toOwnedSlice(p.arena),
            .attributes = attrs,
            .children = try children.toOwnedSlice(p.arena),
        };
    }

    /// One piece of an element's content, appended to `text` or
    /// `children`: true once it was the element's closing tag.
    fn contentItem(p: *Parser, depth: usize, qualified: []const u8, text: *std.ArrayList(u8), children: *std.ArrayList(Element)) DecodeError!bool {
        if (p.pos >= p.body.len) return error.InvalidResponse;
        if (p.startsWith("</")) {
            p.pos += 2;
            if (!std.mem.eql(u8, p.name(), qualified)) return error.InvalidResponse;
            p.skipSpace();
            if (!p.startsWith(">")) return error.InvalidResponse;
            p.pos += 1;
            return true;
        }
        if (p.startsWith("<![CDATA[")) {
            const start = p.pos + "<![CDATA[".len;
            const end = std.mem.indexOfPos(u8, p.body, start, "]]>") orelse return error.InvalidResponse;
            try text.appendSlice(p.arena, p.body[start..end]);
            p.pos = end + 3;
        } else if (p.startsWith("<!--")) {
            try p.skipComment();
        } else if (p.startsWith("<?")) {
            p.pos = (std.mem.indexOfPos(u8, p.body, p.pos + 2, "?>") orelse return error.InvalidResponse) + 2;
        } else if (p.startsWith("<!")) {
            return error.InvalidResponse;
        } else if (p.startsWith("<")) {
            try children.append(p.arena, try p.element(depth + 1));
        } else {
            const end = std.mem.indexOfScalarPos(u8, p.body, p.pos, '<') orelse return error.InvalidResponse;
            try decodeText(p.arena, text, p.body[p.pos..end]);
            p.pos = end;
        }
        return false;
    }

    /// A tag's name: everything up to space, `/`, `>` or the end.
    fn name(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.body.len) : (p.pos += 1) switch (p.body[p.pos]) {
            ' ', '\t', '\r', '\n', '/', '>', '<', '=', '"', '\'' => break,
            else => {},
        };
        return p.body[start..p.pos];
    }

    /// The rest of a start tag: each attribute, `name="value"` or
    /// `name='value'` after whitespace, its value's references decoded.
    /// Returns whether the tag closed itself.
    fn readAttributes(p: *Parser, out: *std.ArrayList(Attribute)) DecodeError!bool {
        while (true) {
            const spaced = p.pos < p.body.len and std.ascii.isWhitespace(p.body[p.pos]);
            p.skipSpace();
            if (p.pos >= p.body.len) return error.InvalidResponse;
            if (p.startsWith(">")) {
                p.pos += 1;
                return false;
            }
            if (p.startsWith("/>")) {
                p.pos += 2;
                return true;
            }
            // An attribute follows the name, or another attribute, only
            // after whitespace.
            if (!spaced) return error.InvalidResponse;
            try out.append(p.arena, try p.attribute());
        }
    }

    /// One `name="value"`, its value's references decoded.
    fn attribute(p: *Parser) DecodeError!Attribute {
        const attr_name = p.name();
        if (attr_name.len == 0) return error.InvalidResponse;
        p.skipSpace();
        if (!p.startsWith("=")) return error.InvalidResponse;
        p.pos += 1;
        p.skipSpace();
        if (p.pos >= p.body.len) return error.InvalidResponse;
        const quote = p.body[p.pos];
        if (quote != '"' and quote != '\'') return error.InvalidResponse;
        const end = std.mem.indexOfScalarPos(u8, p.body, p.pos + 1, quote) orelse return error.InvalidResponse;
        const raw = p.body[p.pos + 1 .. end];
        // XML allows no `<` in an attribute's value.
        if (std.mem.indexOfScalar(u8, raw, '<') != null) return error.InvalidResponse;
        var value: std.ArrayList(u8) = .empty;
        try decodeText(p.arena, &value, raw);
        p.pos = end + 1;
        return .{ .name = attr_name, .value = try value.toOwnedSlice(p.arena) };
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.body.len and std.ascii.isWhitespace(p.body[p.pos])) p.pos += 1;
    }

    fn startsWith(p: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, p.body[p.pos..], prefix);
    }
};

/// `Name` for `x:Name`, and `Name` for itself. Null for a name that is no
/// qualified name: empty, or with an empty prefix, an empty local name, or
/// a second colon.
fn localName(qualified: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, qualified, ':') orelse
        return if (qualified.len == 0) null else qualified;
    const local = qualified[colon + 1 ..];
    if (colon == 0 or local.len == 0 or std.mem.indexOfScalar(u8, local, ':') != null) return null;
    return local;
}

/// Character data with its references decoded: `&lt;`, `&gt;`, `&amp;`,
/// `&quot;`, `&apos;`, and `&#N;` or `&#xH;` for any Unicode scalar value
/// XML allows. Anything else after `&` is refused.
fn decodeText(arena: Allocator, out: *std.ArrayList(u8), raw: []const u8) DecodeError!void {
    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse {
            try out.appendSlice(arena, raw[i..]);
            return;
        };
        try out.appendSlice(arena, raw[i..amp]);
        const semi = std.mem.indexOfScalarPos(u8, raw, amp, ';') orelse return error.InvalidResponse;
        try appendReference(arena, out, raw[amp + 1 .. semi]);
        i = semi + 1;
    }
}

/// The character one reference names, appended.
fn appendReference(arena: Allocator, out: *std.ArrayList(u8), ref: []const u8) DecodeError!void {
    if (namedEntity(ref)) |b| return out.append(arena, b);
    const code = try characterReference(ref);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(code, &buf) catch return error.InvalidResponse;
    try out.appendSlice(arena, buf[0..n]);
}

fn namedEntity(ref: []const u8) ?u8 {
    const named = [_]struct { []const u8, u8 }{
        .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' },
    };
    for (named) |entry| if (std.mem.eql(u8, ref, entry[0])) return entry[1];
    return null;
}

/// `#N` or `#xH`, which must name a character XML allows.
fn characterReference(ref: []const u8) error{InvalidResponse}!u21 {
    if (ref.len < 2 or ref[0] != '#') return error.InvalidResponse;
    const code: u21 = if (ref[1] == 'x')
        std.fmt.parseInt(u21, ref[2..], 16) catch return error.InvalidResponse
    else
        std.fmt.parseInt(u21, ref[1..], 10) catch return error.InvalidResponse;
    const allowed = code == 0x9 or code == 0xa or code == 0xd or
        (code >= 0x20 and code <= 0xd7ff) or
        (code >= 0xe000 and code <= 0xfffd) or
        (code >= 0x10000 and code <= 0x10ffff);
    if (!allowed) return error.InvalidResponse;
    return code;
}

const testing = std.testing;
const core = @import("core");

test "a listing as production sends it: the byte order mark, attributes, an encoded name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), bom ++
        \\<?xml version="1.0" encoding="utf-8"?><EnumerationResults ServiceEndpoint="https://a.blob.core.windows.net/" ContainerName="c"><Prefix>k</Prefix><Blobs><Blob><Name>k1</Name><Properties><Etag>0x8DF3CCF278836DE</Etag><Content-Length>3</Content-Length></Properties></Blob><Blob><Name Encoded="true">k%EF%BF%BE</Name><Properties/></Blob></Blobs><NextMarker /></EnumerationResults>
    );
    try testing.expectEqualStrings("EnumerationResults", root.name);
    try testing.expectEqualStrings("c", root.attribute("ContainerName").?);
    try testing.expectEqualStrings("https://a.blob.core.windows.net/", root.attribute("ServiceEndpoint").?);
    try testing.expectEqual(null, root.attribute("Missing"));
    const blobs = root.child("Blobs").?;
    try testing.expectEqual(2, blobs.children.len);
    try testing.expectEqualStrings("k1", blobs.children[0].childText("Name").?);
    try testing.expectEqualStrings("0x8DF3CCF278836DE", blobs.children[0].child("Properties").?.childText("Etag").?);
    const encoded = blobs.children[1].child("Name").?;
    try testing.expectEqualStrings("true", encoded.attribute("Encoded").?);
    try testing.expectEqualStrings("k%EF%BF%BE", encoded.text);
    try testing.expectEqualStrings("", root.childText("NextMarker").?);
}

test "an error body, with and without the byte order mark" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.\nRequestId:12835688\nTime:2026-11-07T13:00:53.5298744Z</Message></Error>";
    for ([_][]const u8{ body, bom ++ body }) |b| {
        const root = try parse(arena.allocator(), b);
        try testing.expectEqualStrings("Error", root.name);
        try testing.expectEqualStrings("BlobNotFound", root.childText("Code").?);
        try testing.expectStringStartsWith(root.childText("Message").?, "The specified blob does not exist.");
    }
    // A mark anywhere else is text where none may be.
    try testing.expectError(error.InvalidResponse, parse(arena.allocator(), " " ++ bom ++ "<a/>"));
}

test "text and attributes: entities, character references, CDATA and comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\<r><a>1 &lt; 2 &amp;&amp; &quot;q&quot; &apos;s&apos; &gt;</a><b>&#233;&#x1F600;</b><c><![CDATA[<raw & kept>]]></c><d>x<!-- gone -->y</d><e/><s:f a="1/>2" b='>' c = "&amp;&#233;">ns</s:f></r>
    );
    try testing.expectEqualStrings("1 < 2 && \"q\" 's' >", root.childText("a").?);
    try testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x98\x80", root.childText("b").?);
    try testing.expectEqualStrings("<raw & kept>", root.childText("c").?);
    try testing.expectEqualStrings("xy", root.childText("d").?);
    try testing.expectEqualStrings("", root.childText("e").?);
    const f = root.child("f").?;
    try testing.expectEqualStrings("ns", f.text);
    try testing.expectEqualStrings("1/>2", f.attribute("a").?);
    try testing.expectEqualStrings(">", f.attribute("b").?);
    try testing.expectEqualStrings("&\xc3\xa9", f.attribute("c").?);

    // A comment before the root, and a processing instruction inside it.
    const commented = try parse(arena.allocator(), "<!-- c --><r>t</r>");
    try testing.expectEqualStrings("t", commented.text);
    const instructed = try parse(arena.allocator(), "<r>a<?pi x?>b</r>");
    try testing.expectEqualStrings("ab", instructed.text);
}

test "refused: everything that is not a plain, well-formed document" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const deep = core.testing.repeat("<a>", max_depth + 1) ++ core.testing.repeat("</a>", max_depth + 1);
    for ([_][]const u8{
        "",
        "   ",
        bom,
        "just text",
        "<a>",
        "<a></b>",
        "<a></a><b></b>",
        "<a></a>trailing",
        "</a>",
        "<a>&unknown;</a>",
        "<a>&lt</a>",
        "<a>&#0;</a>",
        "<a>&#xD800;</a>",
        "<a>&#x110000;</a>",
        "<a>&#;</a>",
        "<a b=\"unterminated></a>",
        "<a/ >",
        "<a><![CDATA[never closed</a>",
        "<a><!-- never closed</a>",
        "<?xml version='1.0'",
        "<!DOCTYPE a [<!ENTITY x \"boom\">]><a>&x;</a>",
        // A declaration is refused for what it is, not for an entity it
        // happens to define: this one defines none.
        "<!DOCTYPE a><a/>",
        "<?xml version='1.0'?><!DOCTYPE a SYSTEM \"http://example.com/a.dtd\"><a/>",
        "<a><!ELEMENT b ANY></a>",
        "< a></a>",
        // No name at all, where no closing tag can differ from it.
        "<></>",
        "< a/>",
        "<r><></></r>",
        // A prefix or a local name that is empty, or a second colon, is
        // no qualified name. gcp.zig's nightly fuzz job of 2026-09-25
        // found the first, which parsed to an element with no name.
        "<:/>",
        "<a:/>",
        "<:a/>",
        "<a:b:c/>",
        "<:></:>",
        "<r><s:/></r>",
        // Attributes: with no value, an unquoted one, one with `<`, one
        // straight after another, one whose value has a bad reference.
        "<a b></a>",
        "<a b=c></a>",
        "<a b=\"<\"></a>",
        "<a b=\"1\"c=\"2\"></a>",
        "<a b=\"&nope;\"/>",
        "<a =\"1\"/>",
        deep,
    }) |bad| {
        errdefer std.debug.print("accepted: {s}\n", .{bad});
        try testing.expectError(error.InvalidResponse, parse(arena.allocator(), bad));
    }
    // Exactly the limit is fine.
    const ok = core.testing.repeat("<a>", max_depth) ++ core.testing.repeat("</a>", max_depth);
    _ = try parse(arena.allocator(), ok);
}

fn parseAnything(_: void, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Any bytes: a document or InvalidResponse, never a crash or a hang,
    // and every element a document holds has a name.
    if (parse(arena.allocator(), input)) |root| {
        try expectNamed(root);
    } else |err| try testing.expectEqual(error.InvalidResponse, err);
}

fn expectNamed(element: Element) !void {
    try testing.expect(element.name.len > 0);
    for (element.attributes) |a| try testing.expect(a.name.len > 0);
    for (element.children) |c| try expectNamed(c);
}

test "fuzz xml: any bytes parse or are refused cleanly" {
    try core.testing.fuzzBytes({}, parseAnything, .{
        .corpus = &.{
            "<a><b>t</b></a>",
            bom ++ "<?xml version='1.0'?><Error><Code>BlobNotFound</Code></Error>",
            "<a>&#x1F600;&amp;</a>",
            "<a><![CDATA[x]]><!--c--><b/></a>",
            "<!DOCTYPE a><a/>",
            "<a b='>'>",
            "<a b='1' c=\"&amp;\"/>",
            // gcp.zig's 2026-09-25 nightly: a name that is only a colon.
            "<:/>",
        },
    });
}
