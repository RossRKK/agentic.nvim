local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- Subagent sessions, ACP RFD: https://agentclientprotocol.com/rfds/subagents
describe("Subagent sessions", function()
    local child = Child:new()

    --- Starts a session against a scripted agent that answers `initialize`
    --- and `session/new` with the recorded parent session.
    local function start_session()
        child.setup()
        child.lua([[
            local fixture = require("tests.fixtures.subagent_sessions")
            local transport_module = require("agentic.acp.acp_transport")

            _G.sent = {}
            transport_module.create_stdio_transport = function(_config, callbacks)
                local transport = {}
                _G.transport_callbacks = callbacks

                function transport:start()
                    callbacks.on_state_change("connected")
                end

                function transport:stop() end

                function transport:send(data)
                    local request = vim.json.decode(data)
                    _G.sent[#_G.sent + 1] = request
                    local results = {
                        initialize = {
                            protocolVersion = 1,
                            agentCapabilities = { loadSession = true },
                            agentInfo = { name = "claude-agent-acp" },
                        },
                        ["session/new"] = {
                            sessionId = fixture.parent_session_id,
                        },
                    }
                    local result = results[request.method]
                    if result then
                        callbacks.on_message({
                            jsonrpc = "2.0",
                            id = request.id,
                            result = result,
                        })
                    end
                    return true
                end

                return transport
            end

            -- As agent chats are configured: a sub-agent's calls are summarised on it.
            require("agentic.config").tool_calls.subagent_activity = "summary"

            local registry = require("agentic.session_registry")
            _G.session = registry.create(nil, { kind = "new" })
            registry.show_session(_G.session.session_key)
        ]])
        child.lua([[
            vim.wait(2000, function()
                return _G.session.session_id ~= nil
            end)
        ]])
    end

    --- Delivers the recorded frames `first` to `last`.
    --- @param first integer
    --- @param last integer
    local function replay(first, last)
        child.lua(
            [[
            local fixture = require("tests.fixtures.subagent_sessions")
            local first, last = ...
            for i = first, last do
                _G.transport_callbacks.on_message(vim.json.decode(fixture.frames[i]))
            end
        ]],
            { first, last }
        )
        child.flush()
    end

    --- @param pattern string
    --- @param after integer
    --- @return integer index of the first recorded frame past `after` matching `pattern`
    local function frame_index(pattern, after)
        local index = child.lua_get(
            [[
            (function(pattern, after)
                local frames = require("tests.fixtures.subagent_sessions").frames
                for i = after + 1, #frames do
                    if frames[i]:find(pattern, 1, true) then
                        return i
                    end
                end
            end)(...)
        ]],
            { pattern, after }
        )
        assert.is_not_nil(index)
        return index
    end

    --- @return string[] footer rows below the spinner
    local function footer()
        return child.lua_get([[
            (function()
                local ns = vim.api.nvim_create_namespace("agentic_animation")
                local chat = _G.session.widget.buf_nrs.chat
                local mark = vim.api.nvim_buf_get_extmarks(chat, ns, 0, -1, { details = true })[1]
                local rows = {}
                for _, line in ipairs(mark and mark[4].virt_lines or {}) do
                    local text = line[#line][1]
                    if text:find("SubAgent(", 1, true) then
                        rows[#rows + 1] = text
                    end
                end
                return rows
            end)()
        ]])
    end

    before_each(function()
        start_session()
    end)

    after_each(function()
        child.stop()
    end)

    it("tells the agent the client takes subagent sessions", function()
        local initialize = child.lua_get("_G.sent[1]")

        assert.equal("initialize", initialize.method)
        assert.equal({}, initialize.params.clientCapabilities.subagents)
    end)

    it("pins a background sub-agent only while it reports running", function()
        local RUNNING_HEADER =
            " SubAgent(Run sleep and cat notes) · sub-agent: 2 tool calls, last: other(ToolSearch) "
        local first_idle = frame_index('"state":"idle"', 0)
        local running_again = frame_index('"state":"running"', first_idle)
        local last_idle = frame_index('"state":"idle"', running_again)

        replay(1, first_idle - 1)
        local before_idle = footer()
        replay(first_idle, running_again - 1)
        local while_idle = footer()
        replay(running_again, last_idle - 1)
        local resumed = footer()
        replay(last_idle, last_idle)

        assert.equal({ RUNNING_HEADER }, before_idle)
        assert.equal({}, while_idle)
        assert.equal(1, #resumed)
        assert.equal({}, footer())
    end)

    --- @return string[] session ids sent `session/cancel`, in order
    local function cancelled()
        return child.lua_get([[
            vim.iter(_G.sent)
                :filter(function(m) return m.method == "session/cancel" end)
                :map(function(m) return m.params.sessionId end)
                :totable()
        ]])
    end

    it("stops the reply alone, then the sub-agent it left running", function()
        local CHILD = "a4b24fca769b9e1e6"
        local PARENT = child.lua_get(
            [[require("tests.fixtures.subagent_sessions").parent_session_id]]
        )
        replay(1, frame_index('"state":"idle"', 0) - 1)

        child.lua([[
                local key = _G.session.session_key
                _G.session.is_generating = true
                require("agentic").stop_generation({ session = key })
            ]])
        local after_reply_stop = cancelled()
        child.lua([[
                require("agentic").stop_subagents({ session = _G.session.session_key })
            ]])

        assert.equal({ PARENT }, after_reply_stop)
        assert.equal({ PARENT, CHILD }, cancelled())
    end)

    it("stops nothing once the sub-agent is idle", function()
        replay(1, frame_index('"state":"idle"', 0))

        child.lua([[
            require("agentic").stop_subagents({ session = _G.session.session_key })
        ]])

        assert.equal({}, cancelled())
    end)
end)
