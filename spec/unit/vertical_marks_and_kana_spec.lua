--[[--
Vertical mark runs and small-kana placement across kerning modes.

Companion to vertical_ellipsis_stack_spec.  Covers the other "common
weird characters" that ride the vertical mark paths, plus small-kana
placement parity with kerning=best:

  1. ―― (U+2014 double): a non-CJK mark run, same word/pen path as …… —
     must stack down the column in every kerning mode (centre ink in the
     char-box gap, nothing at the column's right edge).
  2. ーー (U+30FC chain): CJK-flagged, so each ー is its own formatter-
     positioned word — verify the chain stays one em per char, centred,
     for regression safety.
  3. Latin words (RENDER_ROTATE path): must render rotated and stacked
     down the column — the top half of the word's sbox alone holding all
     the ink means it was drawn horizontally.
  4. Small kana (っ): the non-HarfBuzz draw paths place glyphs with
     horizontal bearing (x + origin_x, y + baseline - origin_y), which
     parks small ink at the bottom-left of the embox.  Measure the ink
     centre inside the glyph's own sbox under each non-HarfBuzz mode and
     require it to match kerning=best within a few pixels.

  5. Column-top alignment: a column starting with 「 (JLReq 3.1.10
     line-start swallow) puts its first ink at the same offset as a
     漢-first column, in every mode.
  6. text-indent stays on the em grid: 1.2em and 2em indents differ
     from a zero-indent control by whole ems only.

Fixture: spec/unit/fixtures/marks_vertical.epub (fork-only, in this repo
rather than the shared test-data submodule: …… / 値段は――高い。 /
タワーーー / Read this book, plus ゆっくり for small kana).

Run via:
  ./kodev test front -f "Vertical marks"
--]]

describe("Vertical marks", function()
    local DocumentRegistry, ReaderUI, UIManager, Screen, Event
    local epub_path = "spec/front/unit/fixtures/marks_vertical.epub"

    setup(function()
        require("commonrequire")
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        UIManager = require("ui/uimanager")
        Event = require("ui/event")
    end)

    local function vertical_fill(x0, y0, w, h, threshold)
        threshold = threshold or 180
        if w <= 0 or h <= 0 then return 0 end
        local bb = Screen.bb
        if not bb then return 0 end
        local inked_rows = 0
        for row = y0, y0 + h - 1 do
            for col = x0, x0 + w - 1 do
                local px = bb:getPixel(col, row)
                if px:getR() < threshold then
                    inked_rows = inked_rows + 1
                    break
                end
            end
        end
        return inked_rows / h
    end

    -- Ink bounding box inside a rect, or nil when the rect is empty.
    local function ink_bbox(x0, y0, w, h, threshold)
        threshold = threshold or 180
        if w <= 0 or h <= 0 then return nil end
        local bb = Screen.bb
        if not bb then return nil end
        local r0, r1, c0, c1 = nil, nil, nil, nil
        for row = y0, y0 + h - 1 do
            for col = x0, x0 + w - 1 do
                if bb:getPixel(col, row):getR() < threshold then
                    if not r0 then r0 = row end
                    r1 = row
                    if not c0 or col < c0 then c0 = col end
                    if not c1 or col > c1 then c1 = col end
                end
            end
        end
        if not r0 then return nil end
        return r0, c0, r1, c1
    end

    local function collect_all_sboxes(doc)
        local found = {}
        local seen = {}
        for x = Screen:getWidth() - 6, math.floor(Screen:getWidth() * 0.05), -8 do
            for y = 8, Screen:getHeight() - 8, 8 do
                local ok, word = pcall(function()
                    return doc:getWordFromPosition({x=x, y=y})
                end)
                if ok and word and word.word and #word.word > 0 and word.sbox then
                    local sb = word.sbox
                    local key = string.format("%d,%d,%d,%d", sb.x, sb.y, sb.w, sb.h)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(found, {
                            x = sb.x, y = sb.y, w = sb.w, h = sb.h,
                            word = word.word,
                        })
                    end
                end
            end
        end
        return found
    end

    -- The gap between consecutive one-em char boxes that a word box
    -- containing `needle` overlaps: that gap is the run's reserved space,
    -- split evenly between its two equal-advance slots.
    local function find_mark_run_slots(boxes, needle)
        local run_boxes = {}
        for _, b in ipairs(boxes) do
            if b.word:find(needle, 1, true) then
                table.insert(run_boxes, b)
            end
        end
        if #run_boxes == 0 then
            return nil, "no word containing " .. needle .. " found on page"
        end

        local col_x = run_boxes[1].x
        local counts, em_h, em_count = {}, 0, 0
        for _, b in ipairs(boxes) do
            if b.x == col_x then
                counts[b.h] = (counts[b.h] or 0) + 1
                if counts[b.h] > em_count then
                    em_h, em_count = b.h, counts[b.h]
                end
            end
        end
        if em_h == 0 then
            return nil, "no em reference box in run column"
        end

        local chars = {}
        for _, b in ipairs(boxes) do
            if b.x == col_x and b.h == em_h then
                table.insert(chars, b)
            end
        end
        table.sort(chars, function(a, b) return a.y < b.y end)

        for i = 1, #chars - 1 do
            local gap_top = chars[i].y + chars[i].h
            local gap_bottom = chars[i + 1].y
            if gap_top < gap_bottom then
                for _, e in ipairs(run_boxes) do
                    if e.y < gap_bottom and (e.y + e.h) > gap_top then
                        local half = math.floor((gap_bottom - gap_top) / 2)
                        if half < em_h / 2 then
                            return nil, string.format(
                                "gap too small for two slots (gap=%d, em=%d)",
                                gap_bottom - gap_top, em_h)
                        end
                        return {
                            x = chars[i].x, w = chars[i].w,
                            top_y = gap_top,
                            mid_y = gap_top + half,
                            bottom_y = gap_bottom,
                        }
                    end
                end
            end
        end
        return nil, "no char-box gap overlaps a word box containing " .. needle
    end

    -- A vertical chain of `word`-matching single-char boxes (e.g. the ーー
    -- chain), each exactly one em, adjacent down the column.
    local function find_char_chain(boxes, word, min_len)
        local hits = {}
        for _, b in ipairs(boxes) do
            if b.word == word then
                table.insert(hits, b)
            end
        end
        local best = nil
        local cur = nil
        local function flush()
            if cur and (not best or #cur > #best) then best = cur end
            cur = nil
        end
        table.sort(hits, function(a, b)
            if a.x ~= b.x then return a.x < b.x end
            return a.y < b.y
        end)
        for _, b in ipairs(hits) do
            if cur and b.x == cur[#cur].x
                    and math.abs(b.y - (cur[#cur].y + cur[#cur].h)) <= 2 then
                table.insert(cur, b)
            else
                flush()
                cur = { b }
            end
        end
        flush()
        if best and #best >= min_len then return best end
        return nil
    end

    local function find_boxes_with_word(boxes, word)
        local hits = {}
        for _, b in ipairs(boxes) do
            if b.word == word then
                table.insert(hits, b)
            end
        end
        table.sort(hits, function(a, b) return a.y < b.y end)
        return hits
    end

    -- Mirrors ReaderFont:onSetFontKerning (minus the notification).
    local function set_kerning(readerui, mode)
        readerui.document:setFontKerning(mode)
        readerui:handleEvent(Event:new("UpdatePos"))
        readerui.rolling:onGotoPage(1)
        fastforward_ui_events()
    end

    local kerning_modes = {
        { name = "off",  mode = 0 },
        { name = "fast", mode = 1 },
        { name = "good", mode = 2 },
        { name = "best", mode = 3 }, -- control: full HarfBuzz
    }
    local non_hb_modes = { 0, 1, 2 }

    describe("mark runs and Latin words", function()
        local readerui, doc

        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(epub_path),
            }
        end)

        teardown(function()
            readerui:onClose()
        end)

        before_each(function()
            UIManager:show(readerui)
            if readerui.styletweak then
                readerui.styletweak.book_style_tweak =
                    "body { writing-mode: vertical-rl !important; }"
                readerui.styletweak.book_style_tweak_enabled = true
                readerui.styletweak:updateCssText(true)
            end
            readerui.rolling:onGotoPage(1)
            fastforward_ui_events()
            doc = readerui.document
        end)

        after_each(function()
            UIManager:quit()
        end)

        for _, m in ipairs(kerning_modes) do
            it("kerning=" .. m.name .. ": ―― stacks down the column", function()
                set_kerning(readerui, m.mode)
                local slots, reason = find_mark_run_slots(collect_all_sboxes(doc), "―")
                if not slots then
                    pending("cannot isolate the ―― geometry: " .. tostring(reason))
                    return
                end
                local label = string.format("[kerning=%s]", m.name)
                local gap_h = slots.bottom_y - slots.top_y
                local cx = slots.x + math.floor(slots.w / 2)
                local center_fill = vertical_fill(cx - 8, slots.top_y, 16, gap_h)
                local edge_fill = vertical_fill(
                    slots.x + slots.w - 6, slots.top_y, 6, gap_h)
                assert.truthy(center_fill >= 0.10,
                    string.format("%s no ― ink at column centre (fill=%.2f)",
                        label, center_fill))
                assert.truthy(edge_fill < 0.05,
                    string.format(
                        "%s ink at column right edge in the ―― gap (fill=%.2f): "..
                        "non-HarfBuzz pen advanced x instead of y (lvfntman.cpp)",
                        label, edge_fill))
            end)

            it("kerning=" .. m.name .. ": ー chain stays centred per em slot", function()
                set_kerning(readerui, m.mode)
                local chain = find_char_chain(collect_all_sboxes(doc), "ー", 2)
                if not chain then
                    pending("no adjacent ー chain found (fixture/layout issue)")
                    return
                end
                local label = string.format("[kerning=%s]", m.name)
                for i, box in ipairs(chain) do
                    local cx = box.x + math.floor(box.w / 2)
                    local center_fill = vertical_fill(cx - 8, box.y, 16, box.h)
                    local edge_fill = vertical_fill(box.x + box.w - 6, box.y, 6, box.h)
                    assert.truthy(center_fill >= 0.10,
                        string.format("%s ー #%d has no ink at column centre (fill=%.2f)",
                            label, i, center_fill))
                    assert.truthy(edge_fill < 0.05,
                        string.format("%s ー #%d ink at column right edge (fill=%.2f)",
                            label, i, edge_fill))
                end
            end)

            it("kerning=" .. m.name .. ": Latin words rotate-stack down the column", function()
                set_kerning(readerui, m.mode)
                local boxes = collect_all_sboxes(doc)
                local latin = nil
                for _, w in ipairs({ "Read", "this", "book" }) do
                    local hits = find_boxes_with_word(boxes, w)
                    if #hits > 0 then
                        latin = hits[1]
                        break
                    end
                end
                if not latin then
                    pending("no Latin word sbox found (fixture/layout issue)")
                    return
                end
                local label = string.format("[kerning=%s]", m.name)
                local half = math.floor(latin.h / 2)
                if half < 8 then
                    pending(string.format("Latin sbox too short to split (h=%d)", latin.h))
                    return
                end
                local top_fill = vertical_fill(latin.x, latin.y, latin.w, half)
                local bottom_fill = vertical_fill(
                    latin.x, latin.y + half, latin.w, latin.h - half)
                assert.truthy(top_fill >= 0.05,
                    string.format("%s Latin word has no ink in its top half (fill=%.2f)",
                        label, top_fill))
                assert.truthy(bottom_fill >= 0.05,
                    string.format(
                        "%s Latin word's lower half is empty (fill=%.2f): the word "..
                        "renders horizontally instead of rotated+stacked down the column",
                        label, bottom_fill))
            end)
        end
    end)

    describe("small kana placement matches kerning=best", function()
        local readerui, doc

        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(epub_path),
            }
        end)

        teardown(function()
            readerui:onClose()
        end)

        before_each(function()
            UIManager:show(readerui)
            if readerui.styletweak then
                readerui.styletweak.book_style_tweak =
                    "body { writing-mode: vertical-rl !important; }"
                readerui.styletweak.book_style_tweak_enabled = true
                readerui.styletweak:updateCssText(true)
            end
            readerui.rolling:onGotoPage(1)
            fastforward_ui_events()
            doc = readerui.document
        end)

        after_each(function()
            UIManager:quit()
        end)

        -- Ink centre of the first っ relative to its own sbox.
        local function kua_offset()
            local hits = find_boxes_with_word(collect_all_sboxes(doc), "っ")
            if #hits == 0 then return nil, "っ sbox not found" end
            local box = hits[1]
            local r0, c0, r1, c1 = ink_bbox(box.x, box.y, box.w, box.h)
            if not r0 then return nil, "っ sbox has no ink" end
            return {
                cx = (c0 + c1) / 2 - box.x,
                cy = (r0 + r1) / 2 - box.y,
            }
        end

        it("kerning off/fast/good centre っ like best does", function()
            set_kerning(readerui, 3)
            local best, why = kua_offset()
            if not best then
                pending("baseline (kerning=best) unavailable: " .. tostring(why))
                return
            end
            local TOL = 4 -- px; matches spec policy of relative geometry only
            for _, mode in ipairs(non_hb_modes) do
                set_kerning(readerui, mode)
                local got, why2 = kua_offset()
                local label = string.format("[kerning=%d]", mode)
                if not got then
                    pending(label .. " unavailable: " .. tostring(why2))
                    return
                end
                assert.truthy(math.abs(got.cx - best.cx) <= TOL,
                    string.format(
                        "%s っ ink centre-x off by %.1fpx vs best (%.1f vs %.1f): "..
                        "non-HarfBuzz vertical placement diverges from the vmtx model",
                        label, math.abs(got.cx - best.cx), got.cx, best.cx))
                assert.truthy(math.abs(got.cy - best.cy) <= TOL,
                    string.format(
                        "%s っ ink centre-y off by %.1fpx vs best (%.1f vs %.1f): "..
                        "non-HarfBuzz vertical placement diverges from the vmtx model",
                        label, math.abs(got.cy - best.cy), got.cy, best.cy))
            end
        end)
    end)

    describe("column-top alignment for leading quotes", function()
        local readerui, doc

        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(epub_path),
            }
        end)

        teardown(function()
            readerui:onClose()
        end)

        before_each(function()
            UIManager:show(readerui)
            if readerui.styletweak then
                readerui.styletweak.book_style_tweak =
                    "body { writing-mode: vertical-rl !important; }"
                readerui.styletweak.book_style_tweak_enabled = true
                readerui.styletweak:updateCssText(true)
            end
            readerui.rolling:onGotoPage(1)
            fastforward_ui_events()
            doc = readerui.document
        end)

        after_each(function()
            UIManager:quit()
        end)

        -- First ink row of `word`'s box, allowing one em of overhang above the
        -- box (an unswallowed in-slot shift can push ink outside the slot).
        local function first_ink_offset(word_str)
            local hits = find_boxes_with_word(collect_all_sboxes(doc), word_str)
            if #hits == 0 then return nil, "sbox not found: " .. word_str end
            local box = hits[1]
            local em = box.h
            local win_y = math.max(0, box.y - em)
            local win_h = (box.y + box.h + em) - win_y
            local r0 = ink_bbox(box.x, win_y, box.w, win_h)
            if not r0 then return nil, "no ink near sbox of " .. word_str end
            return { off = r0 - box.y, y = box.y }
        end

        for _, m in ipairs(kerning_modes) do
            it("kerning=" .. m.name .. ": quote-first column tops align with kanji-first", function()
                set_kerning(readerui, m.mode)
                local q, qwhy = first_ink_offset("「")
                local k, kwhy = first_ink_offset("漢")
                if not q then pending(qwhy) return end
                if not k then pending(kwhy) return end
                local label = string.format("[kerning=%s]", m.name)
                -- Slots must align (layout contract)...
                assert.truthy(math.abs(q.y - k.y) <= 2,
                    string.format("%s slot tops differ: quote y=%d vs kanji y=%d",
                        label, q.y, k.y))
                -- ...and so must the ink: JLReq 3.1.10 line-start swallow keeps
                -- a leading opening bracket's ink on the column top instead of
                -- shifting it by the JFM in-slot cwa (about half an em).
                assert.truthy(math.abs(q.off - k.off) <= 3,
                    string.format(
                        "%s quote-first ink off by %.0fpx vs kanji-first "..
                        "(offsets %d vs %d): JLReq 3.1.10 line-start swallow missing",
                        label, math.abs(q.off - k.off), q.off, k.off))
            end)
        end
    end)

    describe("text-indent stays on the em grid", function()
        local readerui, doc

        setup(function()
            readerui = ReaderUI:new{
                dimen = Screen:getSize(),
                document = DocumentRegistry:openDocument(epub_path),
            }
        end)

        teardown(function()
            readerui:onClose()
        end)

        before_each(function()
            UIManager:show(readerui)
            if readerui.styletweak then
                readerui.styletweak.book_style_tweak =
                    "body { writing-mode: vertical-rl !important; }"
                readerui.styletweak.book_style_tweak_enabled = true
                readerui.styletweak:updateCssText(true)
            end
            readerui.rolling:onGotoPage(1)
            fastforward_ui_events()
            doc = readerui.document
        end)

        after_each(function()
            UIManager:quit()
        end)

        local function first_word_box(word_str)
            local hits = find_boxes_with_word(collect_all_sboxes(doc), word_str)
            if #hits == 0 then return nil end
            return hits[1]
        end

        for _, m in ipairs(kerning_modes) do
            it("kerning=" .. m.name .. ": indents differ from control in whole ems", function()
                set_kerning(readerui, m.mode)
                local control = first_word_box("べ")     -- text-indent: 0
                local ind12   = first_word_box("ぜ")     -- text-indent: 1.2em
                local ind20   = first_word_box("ぽ")     -- text-indent: 2em
                if not control or not ind12 or not ind20 then
                    pending("indent-control words not found (fixture/layout issue)")
                    return
                end
                local label = string.format("[kerning=%s]", m.name)
                local em = control.h -- single-char CJK box = one em slot
                local d12 = ind12.y - control.y
                local d20 = ind20.y - control.y
                assert.truthy(d12 > 0 and d20 > d12,
                    string.format("%s indent deltas not ordered: 1.2em=%d 2em=%d",
                        label, d12, d20))
                -- The 2em case is exact by construction; 1.2em (28px at the
                -- fixture's 24px em) is what lengthToPx truncates — vertical
                -- mode must snap it back onto the em grid.
                assert.truthy(d12 % em == 0,
                    string.format(
                        "%s 1.2em indent = %dpx, not a whole em (%dpx): "..
                        "vertical text-indent off the embox grid",
                        label, d12, em))
                assert.truthy(d20 % em == 0,
                    string.format("%s 2em indent = %dpx, not a whole em (%dpx)",
                        label, d20, em))
            end)
        end
    end)
end)
