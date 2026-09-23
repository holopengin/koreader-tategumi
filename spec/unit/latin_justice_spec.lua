--[[--
Latin text: justice supplies the line breaks *and* the spacing.

This checks the fork-only hook that lets justice (a Rust dynamic-programming
justifier, vendored under base/thirdparty/justice) take over crengine's justify
step for plain Latin prose. It uses crengine diagnostic counters plus word
boxes rather than screenshot pixels so it can run in the existing unit
environment.

Three things are asserted:

  1. the solver is actually reached and produces a whole-paragraph plan;
  2. the resulting lines really do end at the right margin;
  3. prose it is not entitled to touch (left-aligned here) is left alone.

(1) matters on its own because (2) would also pass with the hook removed -
crengine's own justify would still fill the line.
--]]

describe("Latin justice justify #latin_justice", function()
    local DocumentRegistry, ReaderUI, Screen, UIManager
    local html_path = "/tmp/koreader_latin_justice.xhtml"

    setup(function()
        require("commonrequire")
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        DocumentRegistry = require("document/documentregistry")
        ReaderUI         = require("apps/reader/readerui")
        Screen           = require("device").screen
        UIManager        = require("ui/uimanager")
    end)

    local function ensure_html_fixture(text_align)
        -- One long, unbroken Latin paragraph: no <br>, no CJK, no floats or
        -- inline boxes, horizontal writing mode - i.e. every condition the
        -- eligibility gate wants.
        local phrase = "The quick brown fox jumps over the lazy dog while "
                    .. "sixty pickaxed dwarves dig happily beneath the "
                    .. "wobbling bridge, and nobody at all complains. "
        local body = string.rep(phrase, 60)
        local html = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<meta charset="UTF-8"/>
<title>latin justice</title>
<style>
html, body { margin: 0; padding: 0; }
body { font-family: serif; }
p { margin: 0; text-align: ]] .. text_align .. [[; text-align-last: ]] .. text_align .. [[; }
</style>
</head>
<body><p>]] .. body .. [[</p></body>
</html>]]
        local f = assert(io.open(html_path, "wb"))
        f:write(html)
        f:close()
        return html_path
    end

    local function open_reader(text_align)
        local readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(ensure_html_fixture(text_align)),
        }
        UIManager:show(readerui)
        -- Both of these exist to invalidate any cached layout: reset after
        -- them, so the counters describe the render we then force.
        readerui.document:setFontSize(24)
        readerui.document._document:resetJusticeStats()
        return readerui
    end

    local function render_and_read(readerui)
        readerui.rolling:onGotoPage(1)
        fastforward_ui_events()
        local seen, planned, lines, spaced =
            readerui.document._document:getJusticeStats()
        readerui:onClose()
        UIManager:quit()
        return seen, planned, lines, spaced
    end

    -- Group the page's words into visual lines by their box's top edge, and
    -- report how far right each one reaches.
    local function collect_lines(doc)
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local step_x = math.max(4, math.floor(sw / 100))
        local step_y = math.max(4, math.floor(sh / 100))
        local lines, seen_words = {}, {}
        for y = 4, sh - 4, step_y do
            for x = 4, sw - 4, step_x do
                local ok, w = pcall(function()
                    return doc:getWordFromPosition({x = x, y = y})
                end)
                if ok and w and w.word and #w.word > 0 and w.sbox then
                    local key = w.sbox.y
                    local line = lines[key]
                    if not line then
                        line = { y = key, right = 0, count = 0, uniq = {} }
                        lines[key] = line
                    end
                    line.right = math.max(line.right, w.sbox.x + w.sbox.w)
                    -- Sampling a line repeatedly reports the same word many
                    -- times; count each distinct word-once-at-this-x only.
                    local word_key = string.format("%d_%d_%s", w.sbox.x, w.sbox.y, w.word)
                    if not line.uniq[word_key] then
                        line.uniq[word_key] = true
                        line.count = line.count + 1
                    end
                end
            end
        end
        local list = {}
        for _, line in pairs(lines) do table.insert(list, line) end
        table.sort(list, function(a, b) return a.y < b.y end)
        return list
    end

    it("hands justified Latin paragraphs to the solver", function()
        local seen, planned, lines, spaced = render_and_read(open_reader("justify"))
        print(string.format("[latin_justice] seen=%d planned=%d lines=%d spaced=%d",
            seen, planned, lines, spaced))
        if seen == 0 and planned == 0 then
            pending("crengine was built without justice (USE_JUSTICE=0)")
            return
        end
        assert.truthy(seen > 0, "no paragraphs were offered to justice")
        assert.truthy(planned > 0,
            "the eligibility gate refused every paragraph; justice never ran")
        assert.truthy(planned == seen,
            string.format("planned=%d of seen=%d paragraphs; something in the gate is over-eager",
                planned, seen))
        assert.truthy(lines > planned,
            "expected more lines than paragraphs (i.e. real wrapping)")
        assert.truthy(spaced > 0,
            "the solver planned lines but no spacing was applied at align time")
    end)

    it("fills justified Latin lines to the right margin", function()
        local readerui = open_reader("justify")
        readerui.rolling:onGotoPage(1)
        fastforward_ui_events()
        local list = collect_lines(readerui.document)
        readerui:onClose()
        UIManager:quit()

        local full, filled, worst = 0, 0, -1
        local right_edge = 0
        for _, line in ipairs(list) do right_edge = math.max(right_edge, line.right) end
        for _, line in ipairs(list) do
            -- A line with four or more words is never the ragged last line of
            -- a paragraph at this font size, so it has to have been justified.
            if line.count >= 4 then
                full = full + 1
                local shortfall = right_edge - line.right
                if shortfall <= 4 then filled = filled + 1 end
                if shortfall > worst then worst = shortfall end
            end
        end
        print(string.format("[latin_justice] right_edge=%d full_lines=%d filled=%d worst=%d",
            right_edge, full, filled, worst))
        assert.truthy(full >= 4,
            string.format("only %d multi-word lines found on the page", full))
        assert.truthy(filled >= math.ceil(full * 0.8),
            string.format("%d of %d lines reached the margin, worst shortfall %dpx",
                filled, full, worst))
    end)

    it("leaves non-justified prose to the greedy path", function()
        local seen, planned, lines, spaced = render_and_read(open_reader("left"))
        print(string.format("[latin_justice left-aligned] seen=%d planned=%d lines=%d spaced=%d",
            seen, planned, lines, spaced))
        if seen == 0 and planned == 0 then
            pending("crengine was built without justice (USE_JUSTICE=0)")
            return
        end
        assert.truthy(seen > 0, "no paragraphs were offered to justice")
        assert.truthy(planned == 0,
            string.format("justice planned %d paragraphs of left-aligned text; it must only touch justification",
                planned))
        assert.truthy(spaced == 0, "spacing was applied to non-justified text")
    end)
end)
