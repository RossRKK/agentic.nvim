local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Theme = require("agentic.theme")

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

--- @type table<agentic.Theme.SpinnerState, number>
local TIMING = {
    generating = 200,
    thinking = 600,
    searching = 600,
    busy = 100,
}

-- A pinned footer line past this many rows buries the chat it sits below.
local FOOTER_MAX_ROWS = 2
local ELLIPSIS = "…"

--- @alias agentic.ui.StatusAnimation.VirtLine [string, string][] Text and highlight group chunks

--- Spinner and footer, kept as virtual lines below the chat buffer's last line.
--- @class agentic.ui.StatusAnimation
--- @field _bufnr number
--- @field _state? agentic.Theme.SpinnerState
--- @field _next_frame_handle? uv.uv_timer_t
--- @field _spinner_idx number Index of the frame on screen; 0 before the first
--- @field _footer agentic.ui.StatusAnimation.VirtLine[]
--- @field _extmark_id? number
--- @field _epoch number Bumped by every `start`; a stale frame reschedules nothing
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _next_frame_handle = nil,
        _spinner_idx = 0,
        _footer = {},
        _extmark_id = nil,
        _epoch = 0,
    }, StatusAnimation)

    instance:_follow_buffer_end()

    return instance
end

--- An extmark stays on its line when lines are appended below it.
--- Regression: status_animation.test.lua::"stays below lines appended between frames"
function StatusAnimation:_follow_buffer_end()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    vim.api.nvim_buf_attach(self._bufnr, false, {
        on_lines = function()
            if self._extmark_id then
                self:_draw()
            end
        end,
    })
end

--- @param state agentic.Theme.SpinnerState
function StatusAnimation:start(state)
    self:_cancel_next_frame()

    -- `_cancel_next_frame` cannot un-queue an already-fired `vim.defer_fn` callback.
    -- Regression: status_animation.test.lua::"drops a stale frame instead of scheduling a successor"
    self._epoch = self._epoch + 1

    self._state = state
    self._spinner_idx = 0
    self:_render_frame(self._epoch)
end

--- Stops the spinner; the footer stays.
function StatusAnimation:stop()
    self:_cancel_next_frame()
    self._state = nil
    self:_draw()
end

--- @param footer agentic.ui.StatusAnimation.VirtLine[] Drawn below the spinner, or alone while it is stopped
function StatusAnimation:set_footer(footer)
    self._footer = footer
    self:_draw()
end

function StatusAnimation:_cancel_next_frame()
    if self._next_frame_handle then
        pcall(function()
            self._next_frame_handle:stop()
        end)
        pcall(function()
            self._next_frame_handle:close()
        end)
        self._next_frame_handle = nil
    end
end

--- @param epoch number Epoch this frame was scheduled with
function StatusAnimation:_render_frame(epoch)
    if epoch ~= self._epoch then
        return
    end

    if not self._state or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local frame_count = #(
        Config.spinner_chars[self._state] or Config.spinner_chars.generating
    )
    self._spinner_idx = (self._spinner_idx % frame_count) + 1

    self:_draw()

    local delay = TIMING[self._state] or TIMING.generating
    self._next_frame_handle = vim.defer_fn(function()
        self:_render_frame(epoch)
    end, delay)
end

--- Places the spinner and the footer below the buffer's last line.
function StatusAnimation:_draw()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    --- @type agentic.ui.StatusAnimation.VirtLine[]
    local body = {}
    if self._state then
        body = { self:_build_spinner_line(), { { "" } } }
    end
    vim.list_extend(body, self:_fit_footer())

    if #body == 0 then
        if self._extmark_id then
            pcall(
                vim.api.nvim_buf_del_extmark,
                self._bufnr,
                NS_ANIMATION,
                self._extmark_id
            )
        end
        self._extmark_id = nil
        return
    end

    local virt_lines = { { { "" } } }
    vim.list_extend(virt_lines, body)

    local line_count = vim.api.nvim_buf_line_count(self._bufnr)
    local following = self:_list_following_windows(line_count)
    local rows_before = vim.tbl_map(function(winid)
        return self:_count_end_rows(winid, line_count)
    end, following)

    self._extmark_id = vim.api.nvim_buf_set_extmark(
        self._bufnr,
        NS_ANIMATION,
        line_count - 1,
        0,
        {
            id = self._extmark_id,
            virt_lines = virt_lines,
            virt_lines_above = false,
            -- A sub-agent header in the footer is often wider than the chat.
            -- Regression: status_animation.test.lua::"wraps a footer line wider than the window"
            virt_lines_overflow = "wrap",
        }
    )

    -- Auto-scroll runs before the status changes, so new rows would open below a following window's view.
    -- Regression: status_animation.test.lua::"scrolls a window that follows the end to show added rows"
    -- Regression: status_animation.test.lua::"scrolls a following window when a footer line wraps onto another row"
    for i, winid in ipairs(following) do
        if self:_count_end_rows(winid, line_count) > rows_before[i] then
            vim.api.nvim_win_call(winid, function()
                vim.cmd("noautocmd normal! zb")
            end)
        end
    end
end

--- A window with its cursor on the last line follows the end, as auto-scroll leaves it.
--- @param line_count integer
--- @return integer[] winids
function StatusAnimation:_list_following_windows(line_count)
    return vim.tbl_filter(function(winid)
        return BufHelpers.is_win_usable(winid)
            and vim.api.nvim_win_get_cursor(winid)[1] == line_count
    end, vim.fn.win_findbuf(self._bufnr))
end

--- Wrapped virtual lines take more rows than there are lines, so the window measures them.
--- @param winid integer
--- @param line_count integer
--- @return integer rows Screen rows from the buffer's last line down, its virtual lines included
function StatusAnimation:_count_end_rows(winid, line_count)
    return vim.api.nvim_win_text_height(winid, { start_row = line_count - 1 }).all
end

--- Each footer line cut to FOOTER_MAX_ROWS rows of the window showing the chat; with none, left whole.
--- Regression: status_animation.test.lua::"cuts a footer line to two rows with an ellipsis"
--- @return agentic.ui.StatusAnimation.VirtLine[] footer
function StatusAnimation:_fit_footer()
    local winid = BufHelpers.find_visible_win(self._bufnr)
    if not winid then
        return self._footer
    end

    local info = vim.fn.getwininfo(winid)[1]
    local max_width = FOOTER_MAX_ROWS * (info.width - info.textoff)
    return vim.tbl_map(function(line)
        return self:_cut_line(line, max_width)
    end, self._footer)
end

--- @param line agentic.ui.StatusAnimation.VirtLine
--- @param max_width integer Display cells the line may take, its ellipsis included
--- @return agentic.ui.StatusAnimation.VirtLine cut
function StatusAnimation:_cut_line(line, max_width)
    local texts = vim.tbl_map(function(chunk)
        return chunk[1]
    end, line)
    if vim.fn.strdisplaywidth(table.concat(texts)) <= max_width then
        return line
    end

    --- @type agentic.ui.StatusAnimation.VirtLine
    local cut = {}
    local room = max_width - vim.fn.strdisplaywidth(ELLIPSIS)
    for _, chunk in ipairs(line) do
        local width = vim.fn.strdisplaywidth(chunk[1])
        if width > room then
            cut[#cut + 1] =
                { self:_cut_text(chunk[1], room) .. ELLIPSIS, chunk[2] }
            return cut
        end
        cut[#cut + 1] = chunk
        room = room - width
    end
    return cut
end

--- @param text string
--- @param room integer Display cells the kept text may take
--- @return string kept
function StatusAnimation:_cut_text(text, room)
    --- @type string[]
    local kept = {}
    local width = 0
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
        width = width + vim.fn.strdisplaywidth(char)
        if width > room then
            break
        end
        kept[#kept + 1] = char
    end
    return table.concat(kept)
end

--- @return agentic.ui.StatusAnimation.VirtLine spinner_line
function StatusAnimation:_build_spinner_line()
    local spinner_chars = Config.spinner_chars[self._state]
        or Config.spinner_chars.generating

    local char = spinner_chars[self._spinner_idx] or spinner_chars[1]

    local display_text = string.format(" %s %s ", char, self._state)

    local hl_group = Theme.get_spinner_hl_group(self._state)

    local virt_text = { { display_text, hl_group } }

    -- A background session animates in its own tab, so the centring padding must measure that window.
    local winid = BufHelpers.find_visible_win(self._bufnr)
    if winid then
        local win_width = vim.api.nvim_win_get_width(winid)
        local text_width = vim.fn.strdisplaywidth(display_text)
        if win_width > text_width then
            local padding = math.floor((win_width - text_width) / 2)
            table.insert(virt_text, 1, { string.rep(" ", padding), "Normal" })
        end
    end

    return virt_text
end

return StatusAnimation
