local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local StatusAnimation = require("agentic.ui.status_animation")

describe("agentic.ui.StatusAnimation", function()
    local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

    local bufnr
    local animation

    --- Handle set, not a count: `tabclose!` closes the CURRENT tab, and the
    --- cross-tab cases end on the original one, so a count-based loop shuts the
    --- baseline tab and leaves the test-created one alive.
    --- @type table<integer, true>
    local base_tabs

    --- Tracked so `after_each` closes them even when an assertion throws.
    --- Deleting a buffer only swaps the window to another buffer, so buffer
    --- teardown cannot substitute for closing a float.
    --- @type integer[]
    local extra_wins

    --- @param winid integer
    --- @return integer winid
    local function track_win(winid)
        extra_wins[#extra_wins + 1] = winid
        return winid
    end

    before_each(function()
        base_tabs = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tab] = true
        end
        extra_wins = {}
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
        animation = StatusAnimation:new(bufnr)
    end)

    after_each(function()
        animation:stop()
        animation = nil

        for _, winid in ipairs(extra_wins) do
            if vim.api.nvim_win_is_valid(winid) then
                pcall(vim.api.nvim_win_close, winid, true)
            end
        end

        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tabs[tab] and vim.api.nvim_tabpage_is_valid(tab) then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tab)
                    vim.cmd("tabclose!")
                end)
            end
        end

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    --- @return table extmarks
    local function extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            NS_ANIMATION,
            0,
            -1,
            { details = true }
        )
    end

    --- Animation row of the rendered extmark, nil when nothing is drawn.
    --- @return table|nil chunks
    local function animation_chunks()
        local marks = extmarks()
        if #marks == 0 then
            return nil
        end
        local virt_lines = marks[1][4].virt_lines
        return virt_lines and virt_lines[2]
    end

    describe("frame scheduling", function()
        --- @type TestStub
        local defer_stub
        local scheduled

        before_each(function()
            scheduled = {}
            defer_stub = spy.stub(vim, "defer_fn")
            defer_stub:invokes(function(callback)
                scheduled[#scheduled + 1] = callback
                return nil
            end)
        end)

        after_each(function()
            defer_stub:revert()
        end)

        it("drops a stale frame instead of scheduling a successor", function()
            animation:start("generating")
            assert.equal(1, #scheduled)

            local stale_frame = scheduled[1]

            -- `stop` inside `start` cannot un-queue an already-fired timer, so
            -- this callback still runs. Without the epoch it passes the `_state`
            -- check and starts a second chain at double the frame rate.
            animation:start("generating")
            assert.equal(2, #scheduled)

            stale_frame()

            assert.equal(2, #scheduled)
        end)

        it("leaves exactly one live chain after two starts", function()
            animation:start("generating")
            animation:start("thinking")

            local stale_frame = scheduled[1]
            local live_frame = scheduled[2]

            stale_frame()
            assert.equal(2, #scheduled)

            live_frame()
            assert.equal(3, #scheduled)
        end)

        it("stops rescheduling once stopped", function()
            animation:start("generating")
            local frame = scheduled[1]

            animation:stop()
            frame()

            assert.equal(1, #scheduled)
        end)

        it("bails without scheduling for an invalid buffer", function()
            vim.api.nvim_buf_delete(bufnr, { force = true })

            animation:start("generating")

            assert.equal(0, #scheduled)
        end)
    end)

    describe("rendering", function()
        it("renders an extmark on start", function()
            animation:start("generating")

            assert.equal(1, #extmarks())
        end)

        it("clears the extmark and the state on stop", function()
            animation:start("generating")
            assert.equal(1, #extmarks())

            animation:stop()

            assert.equal(0, #extmarks())
            assert.is_nil(animation._state)
        end)

        it(
            "renders for a buffer whose only window is in another tab",
            function()
                vim.cmd("tabnew")
                vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
                vim.cmd("tabprevious")

                animation:start("generating")

                local chunks = animation_chunks()
                assert.is_not_nil(chunks)
                ---@cast chunks table
                -- Padding + spinner text: window measured despite living in
                -- another tabpage.
                assert.equal(2, #chunks)
            end
        )

        it("stays below lines appended between frames", function()
            animation:start("generating")

            vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "three" })
            vim.api.nvim_buf_set_text(bufnr, 2, 5, 2, 5, { "", "four" })

            local marks = extmarks()
            assert.equal(1, #marks)
            assert.equal(3, marks[1][2])
        end)

        it("renders without padding when no window shows the buffer", function()
            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)
            assert.is_true(chunks[1][1]:find("generating") ~= nil)
        end)

        it("ignores a hidden float when measuring padding", function()
            track_win(vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 40,
                height = 3,
                focusable = false,
                hide = true,
            }))

            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)
        end)
    end)

    describe("footer", function()
        local FOOTER = {
            { { "first sub-agent", "Comment" } },
            { { "second sub-agent", "Comment" } },
        }

        --- @return table[]|nil virt_lines
        local function virt_lines()
            local marks = extmarks()
            return marks[1] and marks[1][4].virt_lines
        end

        it("draws the footer below the spinner", function()
            animation:start("generating")
            animation:set_footer(FOOTER)

            local lines = virt_lines()
            assert.is_not_nil(lines)
            ---@cast lines table[]
            assert.equal(5, #lines)
            assert.is_true(lines[2][1][1]:find("generating") ~= nil)
            assert.equal(FOOTER, { lines[4], lines[5] })
        end)

        it("keeps the footer after the spinner stops", function()
            animation:start("generating")
            animation:set_footer(FOOTER)

            animation:stop()

            assert.equal({ { { "" } }, FOOTER[1], FOOTER[2] }, virt_lines())
        end)

        it("keeps the footer below appended lines with no spinner", function()
            animation:set_footer(FOOTER)

            vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "three" })

            assert.equal(2, extmarks()[1][2])
        end)

        describe("in a window", function()
            local winid

            before_each(function()
                local lines = {}
                for i = 1, 30 do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                winid = track_win(vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    row = 0,
                    col = 0,
                    width = 40,
                    height = 10,
                }))
            end)

            --- @return boolean
            local function shows_whole_end()
                local topline = vim.fn.getwininfo(winid)[1].topline
                local rows = vim.api.nvim_win_text_height(
                    winid,
                    { start_row = topline - 1 }
                ).all
                return rows <= vim.api.nvim_win_get_height(winid)
            end

            it(
                "scrolls a window that follows the end to show added rows",
                function()
                    vim.api.nvim_win_call(winid, function()
                        vim.cmd("normal! G0zb")
                    end)
                    assert.is_true(shows_whole_end())

                    animation:set_footer(FOOTER)

                    assert.is_true(shows_whole_end())
                end
            )

            it("leaves a window reading further up where it is", function()
                vim.api.nvim_win_call(winid, function()
                    vim.cmd("normal! 20Gzt")
                end)
                local topline = vim.fn.getwininfo(winid)[1].topline

                animation:set_footer(FOOTER)

                assert.equal(topline, vim.fn.getwininfo(winid)[1].topline)
            end)
        end)

        it("clears once the footer is empty and the spinner stopped", function()
            animation:set_footer(FOOTER)

            animation:set_footer({})

            assert.equal(0, #extmarks())
        end)
    end)
end)
