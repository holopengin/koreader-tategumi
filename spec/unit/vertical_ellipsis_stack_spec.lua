--[[--
Double-ellipsis (……) stacking spec.

In vertical-rl the two U+2026 of "……" must stack down the column, each in
its own em slot.  With font kerning off/fast/good — the non-HarfBuzz LIGHT
and FreeType draw paths in lvfntman.cpp — the intra-word pen used to
advance rightward instead of down (the HarfBuzz path does `y += w`), so the
second … was drawn beside the first and its reserved slot stayed empty.

Geometry (layout is mode-independent; only the ink differs):

  * every single CJK char reports an sbox of one em slot;
  * the "……" run reports word-level sboxes (getWordFromPosition returns
    strings like "る……"), which do not match char boxes exactly;
  * therefore the ellipsis occupies the *gap* between the char box before
    it and the char box after it, and its two equal-advance slots split
    that gap in half.

The invariant: the LOWER half of the gap (the second …'s reserved slot)
must contain ink.  It is empty exactly when drawing goes side-by-side.

kerning=best (full HarfBuzz) is included as a control: it always stacked.

Run via:
  ./kodev test front -f "Vertical ellipsis"
--]]

describe("Vertical ellipsis", function()
    local DocumentRegistry, ReaderUI, UIManager, Screen, Event
    local epub_path = "spec/front/unit/data/fixtures/vertical_text/rotation_chars.epub"

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

    -- Fraction of rows in the rectangle containing at least one dark pixel.
    -- Copied from vertical_rotation_spec (see its header for the rationale).
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

    -- All word sboxes on the page, deduplicated by (x, y, h).
    -- Note: getWordFromPosition may return several word strings sharing one
    -- origin (e.g. "る…" and "る……" both start at the leading る); distinct
    -- heights are all kept.
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

    -- For the column containing "……": the gap between the char box before
    -- the ellipsis and the char box after it, split into the two reserved
    -- slots.  Returns nil (plus a reason) when the geometry cannot be found.
    local function find_ellipsis_slots(boxes)
        local ellipsis_boxes = {}
        for _, b in ipairs(boxes) do
            if b.word:find("…", 1, true) then
                table.insert(ellipsis_boxes, b)
            end
        end
        if #ellipsis_boxes == 0 then
            return nil, "no word containing … found on page"
        end

        -- Most common sbox height in the ellipsis's column = one em slot.
        local col_x = ellipsis_boxes[1].x
        local counts = {}
        local em_h, em_count = 0, 0
        for _, b in ipairs(boxes) do
            if b.x == col_x then
                counts[b.h] = (counts[b.h] or 0) + 1
                if counts[b.h] > em_count then
                    em_h, em_count = b.h, counts[b.h]
                end
            end
        end
        if em_h == 0 then
            return nil, "no em reference box in ellipsis column"
        end

        -- Char boxes (one em tall) sorted down the column.
        local chars = {}
        for _, b in ipairs(boxes) do
            if b.x == col_x and b.h == em_h then
                table.insert(chars, b)
            end
        end
        table.sort(chars, function(a, b) return a.y < b.y end)

        -- Find the gap between consecutive char boxes that an ellipsis
        -- word-box overlaps: that gap is the reserved ellipsis run.
        for i = 1, #chars - 1 do
            local gap_top = chars[i].y + chars[i].h
            local gap_bottom = chars[i + 1].y
            if gap_top < gap_bottom then
                for _, e in ipairs(ellipsis_boxes) do
                    local e_bottom = e.y + e.h
                    if e.y < gap_bottom and e_bottom > gap_top then
                        -- Both … have the same advance, so the two slots
                        -- split the gap evenly.
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
        return nil, "no char-box gap overlaps an ellipsis word-box"
    end

    -- Mirrors ReaderFont:onSetFontKerning (minus the notification):
    -- the property change triggers REQUEST_RENDER, UpdatePos + a page
    -- redraw flush it to the framebuffer.
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
        { name = "best", mode = 3 }, -- control: always stacked via HarfBuzz
    }

    describe("…… stacks down the column in every kerning mode", function()
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
            it("kerning=" .. m.name .. ": second … draws into its reserved slot", function()
                set_kerning(readerui, m.mode)

                local slots, reason = find_ellipsis_slots(collect_all_sboxes(doc))
                if not slots then
                    pending("cannot isolate the double-ellipsis geometry: " ..
                        tostring(reason))
                    return
                end
                local label = string.format("[kerning=%s]", m.name)
                local gap_top = slots.top_y
                local gap_h = slots.bottom_y - slots.top_y

                -- Sanity: some ellipsis ink exists near the column centre of
                -- the gap (in every mode, stacked or not).
                local cx = slots.x + math.floor(slots.w / 2)
                local center_fill = vertical_fill(cx - 8, gap_top, 16, gap_h)
                -- Discriminator: the buggy non-HarfBuzz pen advances right, so
                -- the second … lands at the RIGHT EDGE of the column band in
                -- the gap rows.  When stacked, both … stay near the centre and
                -- the edge window is empty (only this column's own band is
                -- sampled, so the neighbouring column cannot mask a failure).
                local edge_fill = vertical_fill(
                    slots.x + slots.w - 6, gap_top, 6, gap_h)

                assert.truthy(center_fill >= 0.10,
                    string.format("%s no ellipsis ink at column centre (fill=%.2f)",
                        label, center_fill))
                assert.truthy(edge_fill < 0.05,
                    string.format(
                        "%s ink at the column's right edge in the …… gap (fill=%.2f): "..
                        "the second … renders beside the first instead of stacked — "..
                        "check the non-HarfBuzz draw paths in lvfntman.cpp (the "..
                        "vertical pen must advance y, not x)",
                        label, edge_fill))
            end)
        end
    end)
end)
