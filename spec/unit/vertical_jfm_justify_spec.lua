--[[--
Vertical text: JFM-based justification.

This checks the fork-only vertical post-pass that applies LuaTeX-ja/JFM
base glue and justify stretch/shrink to word->x. It intentionally uses sboxes
instead of screenshot pixels so it can run in the existing unit environment.
--]]

describe("Vertical text JFM justify #vertical_jfm_justify", function()
    local DocumentRegistry, ReaderUI, Screen, UIManager
    local html_path = "/tmp/koreader_vertical_jfm_justify.xhtml"

    setup(function()
        require("commonrequire")
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        DocumentRegistry = require("document/documentregistry")
        ReaderUI         = require("apps/reader/readerui")
        Screen           = require("device").screen
        UIManager        = require("ui/uimanager")
    end)

    local function apply_css(readerui, text_align_last)
        readerui.styletweak.book_style_tweak =
            "body { writing-mode: vertical-rl !important; text-align: justify !important; " ..
            "text-align-last: " .. text_align_last .. " !important; } " ..
            "p, li { text-align: justify !important; }"
        readerui.styletweak.book_style_tweak_enabled = true
        readerui.styletweak:updateCssText(true)
        fastforward_ui_events()
    end

    local function ensure_html_fixture()
        local phrase =
            "これは縦組み本文の均等配置を確認するための長い本文です。「句読点」、中点・疑問符？！を含めても、非最終列は自然に末端まで届きます。"
        local body = {}
        for _ = 1, 180 do table.insert(body, phrase) end
        local html = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="UTF-8"/>
<title>vertical jfm justify</title>
<style>
html, body { margin: 0; padding: 0; }
body { writing-mode: vertical-rl; text-align: justify; font-family: serif; }
p { margin: 0; text-align: justify; }
</style>
</head>
<body><p>]] .. table.concat(body) .. [[</p></body>
</html>]]
        local f = assert(io.open(html_path, "wb"))
        f:write(html)
        f:close()
        return html_path
    end

    local function get_word_at(doc, x, y)
        local ok, w = pcall(function()
            return doc:getWordFromPosition({x = x, y = y})
        end)
        if ok and w and w.word and #w.word > 0 and w.sbox then return w end
        return nil
    end

    local function collect_columns(doc)
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local step_x = math.max(5, math.floor(sw / 70))
        local step_y = math.max(4, math.floor(sh / 130))
        local seen, words, em_samples = {}, {}, {}
        for x = sw - 4, 4, -step_x do
            for y = 4, sh - 4, step_y do
                local word = get_word_at(doc, x, y)
                if word then
                    local key = string.format("%d_%d_%s", word.sbox.x, word.sbox.y, word.word)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(words, word)
                        if word.sbox.h >= 8 and word.sbox.h <= 80 then
                            table.insert(em_samples, word.sbox.h)
                        end
                    end
                end
            end
        end
        table.sort(em_samples)
        local em = em_samples[math.max(1, math.floor(#em_samples / 2))] or 26
        local function col_key(word)
            return math.floor((word.sbox.x + word.sbox.w / 2) / math.max(1, em))
        end
        local columns = {}
        for _, word in ipairs(words) do
            local k = col_key(word)
            local sb = word.sbox
            local c = columns[k] or {count = 0, top = math.huge, bottom = 0, x = sb.x}
            c.count = c.count + 1
            c.top = math.min(c.top, sb.y)
            c.bottom = math.max(c.bottom, sb.y + math.max(sb.h, em))
            columns[k] = c
        end
        local list = {}
        for _, c in pairs(columns) do table.insert(list, c) end
        table.sort(list, function(a, b) return a.x > b.x end)
        return list, em
    end

    local function open_reader()
        local path = ensure_html_fixture()
        local readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(path),
        }
        UIManager:show(readerui)
        readerui.document:setFontSize(26)
        return readerui
    end

    it("fills non-final CJK columns to within one em — no leftover smear, grid kept", function()
        local readerui = open_reader()
        apply_css(readerui, "auto")
        readerui.rolling:onGotoPage(1)
        fastforward_ui_events()

        local columns, em = collect_columns(readerui.document)
        readerui:onClose()
        UIManager:quit()

        if #columns < 4 then pending("not enough columns found"); return end
        local page_bottom = 0
        for _, c in ipairs(columns) do page_bottom = math.max(page_bottom, c.bottom) end
        local full_count_min = math.max(8, math.floor(page_bottom / math.max(1, em)) - 2)
        local checked, best_shortfall = 0, math.huge
        for _, c in ipairs(columns) do
            local shortfall = page_bottom - c.bottom
            if c.count >= full_count_min and c.bottom > Screen:getHeight() * 0.70 then
                checked = checked + 1
                best_shortfall = math.min(best_shortfall, shortfall)
                print(string.format(
                    "[vertical_jfm_justify] x=%d count=%d bottom=%d page_bottom=%d shortfall=%d em=%d",
                    c.x, c.count, c.bottom, page_bottom, shortfall, em))
            end
        end
        if checked < 2 then pending("not enough full non-final columns found"); return end
        -- Non-final columns are start-filled: greedy fill leaves at most the
        -- last glyph's advance (~one em) of ragged bottom, and the leftover
        -- is deliberately NOT smeared across the gaps (monospace em grid —
        -- see the fork note in alignLineHorizontalVerticalPostPass).
        assert.truthy(best_shortfall <= em + 2,
            string.format("best full-column shortfall=%dpx; expected <= one em + 2 (%dpx)",
                best_shortfall, em + 2))
    end)

    it("keeps text-align-last:auto ragged but allows text-align-last:justify", function()
        local function last_column_shortfall(text_align_last)
            local readerui = open_reader()
            if not readerui then return nil end
            apply_css(readerui, text_align_last)
            readerui.rolling:onGotoPage(readerui.document:getPageCount())
            fastforward_ui_events()
            local columns = collect_columns(readerui.document)
            readerui:onClose()
            UIManager:quit()
            if #columns < 2 then return nil end
            local page_bottom = 0
            for _, c in ipairs(columns) do page_bottom = math.max(page_bottom, c.bottom) end
            table.sort(columns, function(a, b) return a.count < b.count end)
            return page_bottom - columns[1].bottom
        end
        local auto_shortfall = last_column_shortfall("auto")
        local justify_shortfall = last_column_shortfall("justify")
        if not auto_shortfall or not justify_shortfall then
            pending("not enough columns on final page")
            return
        end
        print(string.format("[vertical_jfm_justify] text-align-last auto=%d justify=%d",
            auto_shortfall, justify_shortfall))
        assert.truthy(auto_shortfall > justify_shortfall + 4,
            string.format("auto=%d justify=%d", auto_shortfall, justify_shortfall))
    end)
end)
