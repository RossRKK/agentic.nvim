-- Glues together the Chat widget, the agent instance, and the message writer.

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SlashCommands = require("agentic.acp.slash_commands")
local SessionState = require("agentic.acp.session_state")
local SubagentActivity = require("agentic.ui.subagent_activity")
local SubagentRoster = require("agentic.ui.subagent_roster")
local EnvironmentInfo = require("agentic.utils.environment_info")
local Hooks = require("agentic.utils.hooks")

--- @class agentic.SessionManager
--- @field session_id? string
--- @field session_key? integer Registry key, assigned by SessionRegistry.create
--- @field provider_name agentic.UserConfig.ProviderName
--- @field _is_first_message boolean
--- @field is_generating boolean
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field session_state agentic.acp.SessionState
--- @field diff_coordinator agentic.ui.DiffCoordinator
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field subagent_activity agentic.ui.SubagentActivity
--- @field subagent_roster agentic.ui.SubagentRoster
--- @field history_to_send agentic.ui.ChatHistory.Message[]|nil
--- @field _connection_error boolean
--- @field _destroyed boolean Async callbacks must re-check this at RUN time, not capture it
--- @field _session_creation_failed boolean
--- @field _start_prepared boolean
--- @field _on_new_session fun(session: agentic.SessionManager)
--- @field _session_ready_callbacks fun(succeeded: boolean)[]
--- @field pending_replacement_sources? table<any, boolean>
local SessionManager = {}
SessionManager.__index = SessionManager

--- Codepoints, not display cells
local TITLE_MAX_CHARS = 60

--- A sub-agent's own messages, thoughts and checklist, kept off the chat.
local SUBAGENT_CONTENT_UPDATES = {
    user_message_chunk = true,
    agent_message_chunk = true,
    agent_thought_chunk = true,
    plan = true,
}

--- @param update agentic.acp.SessionUpdateMessage
--- @return boolean summarised
local function is_summarised_subagent_update(update)
    return Config.tool_calls.subagent_activity == "summary"
        and SUBAGENT_CONTENT_UPDATES[update.sessionUpdate] == true
        and ACPPayloads.get_parent_tool_call_id(update) ~= nil
end

local ALREADY_STARTED_ERROR = {
    code = -32600,
    message = "Session manager can only be started once",
}

--- @param prompt string
--- @return string title
local function title_from_prompt(prompt)
    local title = vim.trim((prompt:gsub("%s+", " ")))

    if vim.fn.strchars(title) > TITLE_MAX_CHARS then
        -- Character-wise, never `sub`: a byte cut lands mid-UTF-8 sequence.
        title = vim.fn.strcharpart(title, 0, TITLE_MAX_CHARS - 1) .. "…"
    end

    return title
end

--- @param agent agentic.acp.ACPClient
--- @param provider_name agentic.UserConfig.ProviderName
--- @param on_new_session fun(session: agentic.SessionManager)
function SessionManager:new(agent, provider_name, on_new_session)
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")
    local DiffCoordinator = require("agentic.ui.diff_coordinator")

    self = setmetatable({
        session_id = nil,
        provider_name = provider_name,
        _is_first_message = true,
        is_generating = false,
        _connection_error = false,
        _destroyed = false,
        _session_creation_failed = false,
        _start_prepared = false,
        _on_new_session = on_new_session,
        history_to_send = nil,
        _session_ready_callbacks = {},
    }, self)

    self.agent = agent

    self.chat_history = ChatHistory:new()
    self.subagent_activity = SubagentActivity:new()
    self.subagent_roster = SubagentRoster:new()

    self.widget = ChatWidget:new(function(input_text)
        return self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.message_writer:set_provider_name(self.agent.provider_config.name)
    self.message_writer:set_agent_name(function()
        return self:_agent_name()
    end)
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)

    self.permission_manager = PermissionManager:new(self.message_writer)

    -- Strong reference required: `instances_by_buffer` holds only weak values.
    self.file_picker = FilePicker:new(self.widget.buf_nrs.input)
    SlashCommands.setup_completion(self.widget.buf_nrs.input)

    self.diff_coordinator =
        DiffCoordinator:new(self.widget, self.message_writer)

    self.config_options = AgentConfigOptions:new(self.widget.buf_nrs, {
        on_set_mode_success = function(mode_id)
            self:_set_mode_to_chat_header(mode_id)
            self.widget:schedule_header_refresh()
        end,
        on_config_options_applied = function()
            local mode_id = self.config_options:get_mode_id()
            if mode_id then
                self:_set_mode_to_chat_header(mode_id)
            end
            self.widget:schedule_header_refresh()
        end,
        get_agent_instance = function()
            return self.agent
        end,
        get_session_id = function()
            return self.session_id
        end,
    })

    self.session_state =
        SessionState:new(self.config_options, self.agent.provider_config.name)
    self.widget.session_state = self.session_state

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:rerender()
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_optional_window("code")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                self.widget:rerender()
            end
        end
    )

    self.diagnostics_list = DiagnosticsList:new(
        self.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                self.widget:close_optional_window("diagnostics")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:rerender()
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:rerender()
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

function SessionManager:_handle_connection_error()
    if self._destroyed then
        return
    end

    self._connection_error = true
    self._session_creation_failed = true
    SessionManager._resolve_session_ready_callbacks(self, false)
    self.is_generating = false
    self.status_animation:stop()
    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(
            "⚠️ Failed to connect to "
                .. self.agent.provider_config.name
                .. ". Check that the provider is"
                .. " installed and try again"
                .. " with a new session."
        )
    )
end

--- @param succeeded boolean
function SessionManager:_resolve_session_ready_callbacks(succeeded)
    local callbacks = self._session_ready_callbacks or {}
    self._session_ready_callbacks = {}

    if #callbacks == 0 then
        return
    end

    vim.schedule(function()
        if self._destroyed then
            return
        end

        for _, callback in ipairs(callbacks) do
            callback(succeeded)
        end
    end)
end

--- Fires on the next tick when the session is already ready.
--- @param callback fun(session: agentic.SessionManager)
--- @param on_failure fun(session: agentic.SessionManager)|nil
function SessionManager:on_session_ready(callback, on_failure)
    if self.session_id then
        Logger.debug(
            "on_session_ready: session already ready, scheduling callback immediately"
        )
        vim.schedule(function()
            if self._destroyed then
                return
            end

            callback(self)
        end)
        return
    end

    if self._connection_error or self._session_creation_failed then
        if on_failure then
            vim.schedule(function()
                if not self._destroyed then
                    on_failure(self)
                end
            end)
        end
        return
    end

    Logger.debug(
        "on_session_ready: queueing callback, will fire when session ready"
    )
    table.insert(self._session_ready_callbacks, function(succeeded)
        if succeeded then
            callback(self)
        elseif on_failure then
            on_failure(self)
        end
    end)
end

--- @param acp_session_id string
--- @return boolean owns_ready_id
function SessionManager:owns_ready_acp_session(acp_session_id)
    return not self._destroyed and self.session_id == acp_session_id
end

--- Notifies the user with the reason when it answers false.
--- @return boolean can_submit
function SessionManager:can_submit_prompt()
    if self._connection_error then
        Logger.notify(
            "Provider connection failed. Start a new session.",
            vim.log.levels.ERROR
        )
        return false
    end

    if not self.session_id then
        Logger.notify(
            "Session not ready. Wait for initialization to complete.",
            vim.log.levels.WARN
        )
        return false
    end

    return true
end

--- @param update agentic.acp.SessionUpdateMessage
--- @param replaying boolean|nil
function SessionManager:_on_session_update(update, replaying)
    if is_summarised_subagent_update(update) then
        -- The summary on the launching tool call counts tool calls only.
    elseif update.sessionUpdate == "user_message_chunk" then
        if replaying then
            local text = update.content
                and update.content.type == "text"
                and update.content.text
            if text and text ~= "" then
                self.message_writer:write_restoring_message(
                    ACPPayloads.generate_user_message(text)
                )
                self.chat_history:add_message({
                    type = "user",
                    text = text,
                    timestamp = os.time(),
                    provider_name = self.agent.provider_config.name,
                })
            end
        end
    elseif update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "agent_message_chunk" then
        self:_start_spinner("generating")
        self.message_writer:write_message_chunk(update)

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "agent",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self:_start_spinner("thinking")
        self.message_writer:write_message_chunk(update)

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "thought",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "available_commands_update" then
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            self:_set_mode_to_chat_header(update.currentModeId)
            self.widget:schedule_header_refresh()
        end
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        self.session_state:set_usage(update)
        self.widget:schedule_header_refresh()
    elseif update.sessionUpdate == "session_info_update" then
        -- Session metadata is currently informational only
    else
        -- TODO: Move this to Logger from notify to debug when confidence is high
        Logger.notify(
            "Unknown session update type: "
                .. tostring(
                    --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end

    -- Hooks reflect live activity only; a restore replays historical updates.
    if replaying then
        return
    end

    --- @type agentic.UserConfig.SessionUpdateData
    local hook_data = {
        session_id = self.session_id,
        session_key = self.session_key,
        tab_page_id = self.widget:get_visible_tab_id(),
        update = update,
    }
    Hooks.invoke("on_session_update", hook_data)
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @param replaying boolean|nil
function SessionManager:_on_tool_call(tool_call, replaying)
    if self.message_writer.tool_call_blocks[tool_call.tool_call_id] then
        -- Some providers (Mistral) send several `tool_call` for one id.
        self:_on_tool_call_update(tool_call, replaying)
        return
    end

    local owner_id = tool_call.subagent_session_id
        or tool_call.parent_tool_call_id
    if
        owner_id
        and self:_summarise_subagent_tool_call(owner_id, tool_call, replaying)
    then
        return
    end

    self:_write_tool_call(tool_call)
end

--- A sub-agent call that already has a block, because it asked for
--- permission, is updated like any other block.
--- @param parent_id string
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @param replaying boolean|nil
--- @return boolean summarised
function SessionManager:_summarise_subagent_tool_call(
    parent_id,
    tool_call,
    replaying
)
    if
        Config.tool_calls.subagent_activity ~= "summary"
        or self.message_writer.tool_call_blocks[tool_call.tool_call_id]
    then
        return false
    end

    local merged = self.subagent_activity:record(parent_id, tool_call)

    local parent = self.message_writer.tool_call_blocks[parent_id]
    local summary = self.subagent_activity:summarise(parent_id)
    if parent and not vim.deep_equal(parent.subagent_summary, summary) then
        self:_on_tool_call_update(
            { tool_call_id = parent_id, subagent_summary = summary },
            replaying
        )
    end

    if tool_call.status == "completed" then
        self:_reload_edited_file(merged, replaying)
    end

    return true
end

--- Permission buttons render inside the tool call's block.
--- @param tool_call_id string
function SessionManager:_reveal_subagent_tool_call(tool_call_id)
    local hidden = self.subagent_activity:get_tool_call(tool_call_id)
    if hidden and not self.message_writer.tool_call_blocks[tool_call_id] then
        self:_write_tool_call(vim.deepcopy(hidden))
    end
end

--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_write_tool_call(tool_call)
    self.message_writer:write_tool_call_block(tool_call)

    local merged = self.message_writer.tool_call_blocks[tool_call.tool_call_id]
    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_msg = vim.tbl_deep_extend("force", {
        type = "tool_call",
    }, merged)

    self.chat_history:add_message(tool_msg)
end

--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBlock
--- @param replaying boolean|nil
function SessionManager:_on_tool_call_update(tool_call_update, replaying)
    local owner_id = tool_call_update.subagent_session_id
        or tool_call_update.parent_tool_call_id
    if
        owner_id
        and self:_summarise_subagent_tool_call(
            owner_id,
            tool_call_update,
            replaying
        )
    then
        return
    end

    if
        not self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]
    then
        self:_on_tool_call(tool_call_update, replaying)
    else
        self.message_writer:update_tool_call_block(tool_call_update)

        local merged =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]
        --- @type agentic.ui.ChatHistory.ToolCall
        local tool_msg = vim.tbl_deep_extend("force", {
            type = "tool_call",
        }, merged)

        self.chat_history:update_tool_call(
            tool_call_update.tool_call_id,
            tool_msg
        )
    end

    local tracker =
        self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

    local is_terminal = tool_call_update.status == "completed"
        or tool_call_update.status == "failed"
    if is_terminal then
        local is_rejection = tool_call_update.status == "failed"
        self.diff_coordinator:clear(tool_call_update.tool_call_id, is_rejection)
    end

    if
        tool_call_update.status == "completed"
        and tracker
        and tracker.kind
        and ACPPayloads.FILE_MUTATING_KINDS[tracker.kind]
    then
        DiffPreview.cleanup_suggestion_buffer(
            tracker.file_path,
            self.diff_coordinator.diff_state
        )
    end

    -- Terminal status: clear the inline permission buttons.
    if
        tool_call_update.status == "failed"
        or tool_call_update.status == "completed"
    then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    if tool_call_update.status == "completed" and tracker then
        self:_reload_edited_file(tracker, replaying)
    end

    if not self.permission_manager:has_pending() then
        self:_start_spinner("generating")
    end

    self:_refresh_subagent_footer()
end

--- The Agent call headers scroll away as output arrives, so the running ones are pinned to the chat's end.
--- Regression: session_manager.test.lua::"pins each running sub-agent to the end of the chat"
function SessionManager:_refresh_subagent_footer()
    -- A child session reports its own work state, which outlives the parent's turn.
    local ids = self.subagent_roster:working_ids()
    -- Sub-agents run inside a turn, so its end clears any whose Agent call never reported finishing.
    if self.is_generating then
        vim.list_extend(ids, self.message_writer:list_running_launch_ids())
    end
    self.status_animation:set_footer(self.message_writer:list_headers(ids))
end

--- Each announced child session is a block in the chat, its header carrying its work so far.
--- Regression: session_manager.test.lua::"pins a running sub-agent after its parent's turn ends"
--- @param association agentic.acp.SubagentAssociation
--- @param replaying boolean
function SessionManager:_on_subagent_update(association, replaying)
    local child = self.subagent_roster:apply(association, replaying)

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local block = {
        tool_call_id = association.child_session_id,
        kind = "SubAgent",
        argument = child.title or "sub-agent",
        body = child.description and { child.description } or nil,
        status = SubagentRoster.display_status(child),
    }

    if self.message_writer.tool_call_blocks[block.tool_call_id] then
        self.message_writer:update_tool_call_block(block)
    else
        self.message_writer:write_tool_call_block(block)
    end

    self:_refresh_subagent_footer()
end

--- Stops the current work of each sub-agent session working now, leaving the parent's.
--- Regression: session_manager.test.lua::"stop_subagents"
function SessionManager:stop_subagents()
    -- A child confirms the stop with its own idle state, so the roster is left to report it.
    for _, child_session_id in ipairs(self.subagent_roster:stoppable_ids()) do
        self.agent:stop_generation(child_session_id)
        self.permission_manager:cancel_session(child_session_id)
    end
end

--- @param tracker agentic.ui.MessageWriter.ToolCallBlock A completed tool call
--- @param replaying boolean|nil
function SessionManager:_reload_edited_file(tracker, replaying)
    if
        not tracker.kind or not ACPPayloads.FILE_MUTATING_KINDS[tracker.kind]
    then
        return
    end

    vim.cmd.checktime()

    -- Skip the hook during restore replay: the provider replays
    -- historical tool calls as "completed" but no write happened now.
    if
        not replaying
        and type(tracker.file_path) == "string"
        and tracker.file_path ~= ""
    then
        local abs_path = FileSystem.to_absolute_path(tracker.file_path)
        local raw_bufnr = vim.fn.bufnr(abs_path)
        local is_loaded = raw_bufnr ~= -1
            and vim.api.nvim_buf_is_loaded(raw_bufnr)
        --- @type number|nil
        local bufnr = is_loaded and raw_bufnr or nil
        --- @type agentic.UserConfig.FileEditData
        local hook_data = {
            filepath = abs_path,
            session_id = self.session_id,
            session_key = self.session_key,
            tab_page_id = self.widget:get_visible_tab_id(),
            bufnr = bufnr,
        }
        Hooks.invoke("on_file_edit", hook_data)
    end
end

--- NOTE: This is used by users inside hooks, moving/renaming this is a breaking change!
function SessionManager:schedule_header_refresh()
    self.widget:schedule_header_refresh()
end

--- The name `Config.agent_name` gives this session's agent, or nil for the provider's.
--- @return string|nil
function SessionManager:_agent_name()
    if not (Config.agent_name and self.session_id) then
        return nil
    end
    local ok, name = pcall(Config.agent_name, self.session_id)
    if not ok then
        Logger.notify("Error in agent_name: " .. tostring(name))
        return nil
    end
    return name
end

--- @param mode_id string
function SessionManager:_set_mode_to_chat_header(mode_id)
    local mode_name = self.config_options:get_mode_name(mode_id)
    self.widget:render_header(
        "chat",
        string.format("Mode: %s", mode_name or mode_id)
    )
end

--- @param input_text string
--- @return boolean submitted
function SessionManager:_handle_input_submit(input_text)
    -- BEFORE the submit guard, so `/new` escapes a stuck session.
    if input_text:match("^/new%s") or input_text:match("^/new$") then
        self._on_new_session(self)
        return true
    end

    self.todo_list:close_if_all_completed()

    if not self:can_submit_prompt() then
        return false
    end

    --- Sent to the agent, not written to the chat
    --- @type agentic.acp.Content[]
    local prompt = {}

    if self.history_to_send then
        ChatHistory.prepend_restored_messages(self.history_to_send, prompt)
        self.history_to_send = nil
    end

    -- First submit only, so the picker label stays stable.
    if self.chat_history.title == "" then
        self.chat_history.title = title_from_prompt(input_text)
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    if self._is_first_message then
        self._is_first_message = false

        local environment = EnvironmentInfo.get_system_info()
        --- @type agentic.UserConfig.BeforeFirstPromptData
        local first_prompt_hook_data = {
            session_id = self.session_id,
            session_key = self.session_key,
            provider_name = self.agent.provider_config.name,
        }
        local extra_instructions =
            Hooks.invoke_sync("before_first_prompt", first_prompt_hook_data)
        -- The hook runs user code, which can destroy this session.
        if self._destroyed then
            Logger.notify(
                "Session destroyed by the before_first_prompt hook. Prompt not sent.",
                vim.log.levels.WARN
            )
            return false
        end
        if extra_instructions and extra_instructions ~= "" then
            environment = environment .. "\n\n" .. extra_instructions
        end
        local capabilities = self.agent.agent_capabilities
        local prompt_capabilities = capabilities
            and capabilities.promptCapabilities
        -- ACP prefers embedded resources for context; preserve text fallback order.
        -- https://agentclientprotocol.com/protocol/v1/content#embedded-resource
        if
            prompt_capabilities
            and prompt_capabilities.embeddedContext == true
        then
            prompt[#prompt + 1] = {
                type = "resource",
                resource = {
                    uri = "agentic://environment",
                    mimeType = "text/plain",
                    text = environment,
                },
            }
        else
            prompt[#prompt + 1] = { type = "text", text = environment }
        end
    end

    --- Written to the chat widget
    local message_lines = {}

    table.insert(message_lines, input_text)

    if not self.code_selection:is_empty() then
        local code_selection_lines, code_selection_prompt =
            self.code_selection:to_prompt()
        vim.list_extend(message_lines, code_selection_lines)
        vim.list_extend(prompt, code_selection_prompt)
    end

    if not self.file_list:is_empty() then
        local file_list_lines, file_list_prompt = self.file_list:to_prompt()
        vim.list_extend(message_lines, file_list_lines)
        vim.list_extend(prompt, file_list_prompt)
    end

    if not self.diagnostics_list:is_empty() then
        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local diagnostics_lines, diagnostics_prompt =
            self.diagnostics_list:to_prompt(chat_width)
        vim.list_extend(message_lines, diagnostics_lines)
        vim.list_extend(prompt, diagnostics_prompt)
    end

    local user_message = ACPPayloads.generate_user_message(message_lines)
    self.message_writer:write_message(user_message)

    --- @type agentic.ui.ChatHistory.UserMessage
    local user_msg = {
        type = "user",
        text = input_text,
        timestamp = os.time(),
        provider_name = self.agent.provider_config.name,
    }
    self.chat_history:add_message(user_msg)

    self.status_animation:start("thinking")

    --- @type agentic.UserConfig.PromptSubmitData
    local prompt_hook_data = {
        prompt = input_text,
        session_id = self.session_id,
        session_key = self.session_key,
        tab_page_id = self.widget:get_visible_tab_id(),
    }
    Hooks.invoke("on_prompt_submit", prompt_hook_data)

    -- Captured, NOT re-read below: this is the staleness guard.
    local session_id = self.session_id

    self.is_generating = true

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        vim.schedule(function()
            if self._destroyed or self.session_id ~= session_id then
                return
            end

            self.message_writer:write_finish_message(response, err)
            self.status_animation:stop()
            self.is_generating = false
            self:_refresh_subagent_footer()

            --- @type agentic.UserConfig.ResponseCompleteData
            local response_hook_data = {
                session_id = session_id --[[@as string]],
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
                success = err == nil,
                error = err,
            }
            Hooks.invoke("on_response_complete", response_hook_data)
        end)
    end)

    return true
end

--- Every handler re-checks `_destroyed` at RUN time: `__with_subscriber` schedules
--- the call, so dropping the subscriber cannot un-queue an already-queued callback.
--- @param is_replaying (fun(): boolean)|nil
--- @return agentic.acp.ClientHandlers handlers
function SessionManager:_build_handlers(is_replaying)
    is_replaying = is_replaying or function()
        return false
    end

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            if self._destroyed then
                return
            end

            Logger.debug("Agent error: ", err)

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message({
                    "🐞 Agent Error:",
                    "",
                    vim.inspect(err),
                })
            )
        end,

        on_session_update = function(update)
            if self._destroyed then
                return
            end

            self:_on_session_update(update, is_replaying())
        end,

        on_tool_call = function(tool_call)
            if self._destroyed then
                return
            end

            self:_on_tool_call(tool_call, is_replaying())
        end,

        on_tool_call_update = function(tool_call_update)
            if self._destroyed then
                return
            end

            self:_on_tool_call_update(tool_call_update, is_replaying())
        end,

        on_subagent_update = function(association)
            if self._destroyed then
                return
            end

            self:_on_subagent_update(association, is_replaying())
        end,

        on_request_permission = function(request, callback)
            if self._destroyed then
                -- The ONLY handler that owes a JSON-RPC response, so it cannot
                -- return silently: the provider subprocess outlives this session.
                callback(nil)
                return
            end

            Hooks.invoke("on_request_permission", {
                request = request,
                session_id = self.session_id,
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
            })

            self.status_animation:stop()

            local function wrapped_callback(option_id)
                callback(option_id)

                local is_rejection = option_id == "reject_once"
                    or option_id == "reject_always"
                self.diff_coordinator:clear(
                    request.toolCall.toolCallId,
                    is_rejection
                )

                if not self.permission_manager:has_pending() then
                    self:_start_spinner("generating")
                end
            end

            self:_reveal_subagent_tool_call(request.toolCall.toolCallId)
            self.diff_coordinator:show(request.toolCall.toolCallId)
            self.permission_manager:add_request(request, wrapped_callback)
        end,
    }

    return handlers
end

--- @param response agentic.acp.SessionCreationResponse|agentic.acp.LoadSessionResponse
function SessionManager:_apply_start_metadata(response)
    if response.configOptions then
        Logger.debug(self.provider_name, "announced configOptions")
        self:_handle_new_config_options(response.configOptions)
        return
    end

    if response.modes then
        Logger.debug(self.provider_name, "announced legacy mode")
        self.config_options:set_legacy_modes(response.modes)
        self:_set_mode_to_chat_header(response.modes.currentModeId)
    end

    if response.models then
        Logger.debug(self.provider_name, "announced legacy models")
        self.config_options:set_legacy_models(response.models)
    end
end

function SessionManager:_apply_initial_options()
    local function apply_initial_thought_level()
        self.config_options:set_initial_thought_level(
            self.agent.provider_config.default_thought_level
        )
    end

    local will_change_model = self.config_options:set_initial_model(
        self.agent.provider_config.initial_model,
        apply_initial_thought_level
    )

    self.config_options:set_initial_mode(
        self.agent.provider_config.default_mode
    )

    if not will_change_model then
        apply_initial_thought_level()
    end
end

--- Prepares manager-owned UI and handlers for one external startup attempt.
--- @param spec agentic.SessionStartSpec
--- @param is_replaying fun(): boolean
--- @return agentic.acp.ClientHandlers|nil handlers
--- @return agentic.acp.ACPError|nil err
function SessionManager:prepare_start(spec, is_replaying)
    if self._start_prepared then
        return nil, ALREADY_STARTED_ERROR
    end

    self._start_prepared = true
    self._session_creation_failed = false
    self.status_animation:start("busy")

    if spec.kind == "load" then
        local agent_info = self.agent.agent_info
        local welcome_message = self.message_writer:generate_welcome_header(
            self.agent.provider_config.name,
            spec.session_id,
            agent_info and agent_info.version,
            spec.timestamp
        )
        self.message_writer:write_structural_message(
            ACPPayloads.generate_user_message(welcome_message)
        )
    end

    return self:_build_handlers(is_replaying), nil
end

--- Adopts or rejects the result of the manager's external startup attempt.
--- @param spec agentic.SessionStartSpec
--- @param result agentic.SessionStartResult|nil
--- @param err agentic.acp.ACPError|nil
--- @param callback fun(session: agentic.SessionManager, err: agentic.acp.ACPError|nil)|nil
function SessionManager:complete_start(spec, result, err, callback)
    if self._destroyed then
        if result then
            self.agent:cancel_session(result.session_id)
        end
        if callback then
            callback(self, err)
        end
        return
    end

    self.status_animation:stop()

    if err or not result then
        self.session_id = nil
        self._session_creation_failed = true
        if spec.kind == "new" then
            --- @type agentic.UserConfig.CreateSessionResponseData
            local hook_data = {
                session_id = nil,
                session_key = self.session_key,
                tab_page_id = self.widget:get_visible_tab_id(),
                response = nil,
                err = err,
            }
            Hooks.invoke("on_create_session_response", hook_data)
        else
            Logger.notify(
                "Failed to load session: "
                    .. (err and err.message or "unknown error"),
                vim.log.levels.ERROR
            )
        end
        SessionManager._resolve_session_ready_callbacks(self, false)
        if callback then
            callback(self, err)
        end
        return
    end

    self.session_id = result.session_id
    self.chat_history.session_id = result.session_id
    self.chat_history.timestamp = os.time()
    self:_apply_start_metadata(result.response)

    if result.kind == "new" then
        self._is_first_message = true
        self:_apply_initial_options()
    else
        self._is_first_message = false
        self.chat_history.title = spec.title or ""
    end

    local agent_info = self.agent.agent_info
    if result.kind == "new" then
        local welcome_message = self.message_writer:generate_welcome_header(
            self.agent.provider_config.name,
            result.session_id,
            agent_info and agent_info.version,
            spec.timestamp
        )
        self.message_writer:write_structural_message(
            ACPPayloads.generate_user_message(welcome_message)
        )
    else
        local finish_message = string.format(
            "\n### %s Session restored - %s\n-----",
            Config.message_icons.finished,
            os.date("%Y-%m-%d %H:%M:%S")
        )
        self.message_writer:write_message(
            ACPPayloads.generate_agent_message(finish_message)
        )
    end

    if result.kind == "new" then
        --- @type agentic.UserConfig.CreateSessionResponseData
        local hook_data = {
            session_id = result.session_id,
            session_key = self.session_key,
            tab_page_id = self.widget:get_visible_tab_id(),
            response = result.response,
            err = nil,
        }
        Hooks.invoke("on_create_session_response", hook_data)
    end

    SessionManager._resolve_session_ready_callbacks(self, true)
    if callback then
        callback(self, nil)
    end
end

--- @param state agentic.Theme.SpinnerState
function SessionManager:_start_spinner(state)
    if self.is_generating then
        self.status_animation:start(state)
    end
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self.code_selection.get_selected_text()

    if selection then
        self.code_selection:add(selection)
        return true
    end

    return false
end

--- @param buf integer|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @return integer count
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param bufnr integer|nil Defaults to the current buffer
--- @return integer count
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param new_config_options agentic.acp.AnyConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)
    local mode_id = self.config_options:get_mode_id()
    if mode_id then
        self:_set_mode_to_chat_header(mode_id)
    end

    self.widget:schedule_header_refresh()
end

function SessionManager:destroy()
    if self._destroyed then
        return
    end

    self._destroyed = true
    if self.session_id and self.agent and self.agent.cancel_session then
        self.agent:cancel_session(self.session_id)
        self.session_id = nil
    end
    self.is_generating = false
    if self.status_animation then
        self.status_animation:stop()
    end
    if self.permission_manager then
        self.permission_manager:clear()
    end
    self._session_ready_callbacks = {}
    self.pending_replacement_sources = nil
    self.history_to_send = nil
    if self.chat_history then
        self.chat_history.session_id = nil
        self.chat_history.title = ""
        self.chat_history.timestamp = 0
        self.chat_history.messages = {}
    end
    if self.file_list then
        self.file_list:clear()
    end
    if self.code_selection then
        self.code_selection:clear()
    end
    if self.diagnostics_list then
        self.diagnostics_list:clear()
    end
    if self.todo_list then
        self.todo_list:clear()
    end
    if self.config_options then
        self.config_options:clear()
    end
    if self.session_state then
        self.session_state:clear()
    end
    if self.widget.buf_nrs and self.widget.buf_nrs.input then
        SlashCommands.setCommands(self.widget.buf_nrs.input, {})
    end
    self.widget:destroy()
    if self.message_writer then
        self.message_writer:destroy()
    end
end

return SessionManager
