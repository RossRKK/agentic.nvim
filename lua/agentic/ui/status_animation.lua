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

--- Columns a wrapped footer line's continuation rows are indented by.
local CONTINUATION_INDENT = 4

--- @alias agentic.ui.StatusAnimation.VirtLine [string, string][] Text and highlight group chunks

--- Splits a line into rows of at most `width` columns, breaking between words where it can.
--- @param line agentic.ui.StatusAnimation.VirtLine
--- @param width integer
--- @return agentic.ui.StatusAnimation.VirtLine[] rows
local function wrap_line(line, width)
    local line_width = 0
    for _, chunk in ipairs(line) do
        line_width = line_width + vim.fn.strdisplaywidth(chunk[1])
    end
    if line_width <= width or width <= CONTINUATION_INDENT then
        return { line }
    end

    --- @type agentic.ui.StatusAnimation.VirtLine[]
    local rows = { {} }
    local used = 0
    local row_has_text = false

    local function break_row()
        rows[#rows + 1] = { { string.rep(" ", CONTINUATION_INDENT) } }
        used = CONTINUATION_INDENT
        row_has_text = false
    end

    --- @param text string
    --- @param hl string|nil
    local function append(text, hl)
        local row = rows[#rows]
        local last = row[#row]
        if row_has_text and last[2] == hl then
            last[1] = last[1] .. text
        else
            row[#row + 1] = { text, hl }
        end
        used = used + vim.fn.strdisplaywidth(text)
        row_has_text = true
    end

    for _, chunk in ipairs(line) do
        local hl = chunk[2]
        for token in chunk[1]:gmatch("%s*%S*") do
            if
                row_has_text
                and used + vim.fn.strdisplaywidth(token) > width
            then
                token = token:gsub("^%s+", "")
                if token ~= "" then
                    break_row()
                end
            end
            -- A word wider than a whole row is cut wherever the row ends.
            for _, char in ipairs(vim.fn.split(token, "\\zs")) do
                local char_width = vim.fn.strdisplaywidth(char)
                if row_has_text and used + char_width > width then
                    break_row()
                end
                append(char, hl)
            end
        end
    end

    return rows
end

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
    instance:_follow_window_width()

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

--- Wrapped rows are cut to the window's width, so a resize or a new window redraws them.
--- Regression: status_animation.test.lua::"rewraps the footer when the window is resized"
function StatusAnimation:_follow_window_width()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = self._bufnr,
        callback = function()
            if self._extmark_id then
                self:_draw()
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if not vim.api.nvim_buf_is_valid(self._bufnr) then
                return true
            end
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
    -- Virtual lines never wrap, so a footer line wider than the window would be cut off.
    -- Regression: status_animation.test.lua::"wraps a footer line wider than the window"
    local width = self:_text_width()
    for _, line in ipairs(self._footer) do
        vim.list_extend(body, width and wrap_line(line, width) or { line })
    end

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

    local grew = #virt_lines > self:_count_drawn_lines()

    local line_count = vim.api.nvim_buf_line_count(self._bufnr)
    self._extmark_id = vim.api.nvim_buf_set_extmark(
        self._bufnr,
        NS_ANIMATION,
        line_count - 1,
        0,
        {
            id = self._extmark_id,
            virt_lines = virt_lines,
            virt_lines_above = false,
        }
    )

    -- Auto-scroll runs before the status changes, so new rows would open below a following window's view.
    -- Regression: status_animation.test.lua::"scrolls a window that follows the end to show added rows"
    if grew then
        self:_scroll_following_windows(line_count)
    end
end

--- @return integer|nil width Text columns of the window showing the buffer, nil when none does
function StatusAnimation:_text_width()
    local winid = BufHelpers.find_visible_win(self._bufnr)
    if not winid then
        return nil
    end
    local info = vim.fn.getwininfo(winid)[1]
    return info.width - info.textoff
end

--- @return integer count Virtual lines on screen now
function StatusAnimation:_count_drawn_lines()
    if not self._extmark_id then
        return 0
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(
        self._bufnr,
        NS_ANIMATION,
        self._extmark_id,
        { details = true }
    )
    local details = mark[3]
    return details and details.virt_lines and #details.virt_lines or 0
end

--- A window with its cursor on the last line follows the end, as auto-scroll leaves it.
--- @param line_count integer
function StatusAnimation:_scroll_following_windows(line_count)
    for _, winid in ipairs(vim.fn.win_findbuf(self._bufnr)) do
        if
            BufHelpers.is_win_usable(winid)
            and vim.api.nvim_win_get_cursor(winid)[1] == line_count
        then
            vim.api.nvim_win_call(winid, function()
                vim.cmd("noautocmd normal! zb")
            end)
        end
    end
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
