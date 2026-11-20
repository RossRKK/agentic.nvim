--- Sub-agent tool calls kept off the chat, counted per launching tool call.
--- @class agentic.ui.SubagentActivity
--- @field _tool_calls table<string, agentic.ui.MessageWriter.ToolCallBlock> Merged state by tool call id
--- @field _child_ids table<string, string[]> Tool call ids by launching tool call id, in arrival order
local SubagentActivity = {}
SubagentActivity.__index = SubagentActivity

--- @return agentic.ui.SubagentActivity
function SubagentActivity:new()
    return setmetatable({ _tool_calls = {}, _child_ids = {} }, self)
end

--- @param parent_id string
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @return agentic.ui.MessageWriter.ToolCallBlock merged
function SubagentActivity:record(parent_id, tool_call)
    local id = tool_call.tool_call_id
    local previous = self._tool_calls[id]

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local merged
    if previous then
        merged = vim.tbl_deep_extend("force", previous, tool_call)
    else
        merged = vim.deepcopy(tool_call)
        local child_ids = self._child_ids[parent_id] or {}
        child_ids[#child_ids + 1] = id
        self._child_ids[parent_id] = child_ids
    end

    self._tool_calls[id] = merged
    return merged
end

--- @param parent_id string
--- @return agentic.ui.MessageWriter.SubagentSummary|nil summary
function SubagentActivity:summarise(parent_id)
    local child_ids = self._child_ids[parent_id]
    if not child_ids then
        return nil
    end

    local latest = self._tool_calls[child_ids[#child_ids]]

    --- @type agentic.ui.MessageWriter.SubagentSummary
    local summary = {
        tool_call_count = #child_ids,
        latest_kind = latest.kind,
        latest_argument = latest.argument,
    }
    return summary
end

--- @param tool_call_id string
--- @return agentic.ui.MessageWriter.ToolCallBlock|nil tool_call
function SubagentActivity:get_tool_call(tool_call_id)
    return self._tool_calls[tool_call_id]
end

return SubagentActivity
