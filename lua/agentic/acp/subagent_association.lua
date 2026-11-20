--- `subagent_update` payloads, parsed at the ACP boundary.
--- ACP RFD "Subagent Sessions": https://agentclientprotocol.com/rfds/subagents
--- @class agentic.acp.SubagentAssociationModule
local M = {}

--- @type table<string, agentic.acp.SubagentWorkStateKind>
local KNOWN_STATES = {
    running = "running",
    requires_action = "requires_action",
    idle = "idle",
    unknown = "unknown",
}

--- @param parent_session_id string The outer `sessionId`: the child's immediate parent
--- @param update table The raw `subagent_update`
--- @return agentic.acp.SubagentAssociation|nil association nil when the update names no child
function M.parse(parent_session_id, update)
    if type(update.sessionId) ~= "string" or update.sessionId == "" then
        return nil
    end

    --- @type agentic.acp.SubagentAssociation
    local association = {
        child_session_id = update.sessionId,
        parent_session_id = parent_session_id,
        title = type(update.title) == "string" and update.title or nil,
        description = type(update.description) == "string"
                and update.description
            or nil,
        state = M._parse_state(update.state),
    }
    return association
end

--- @param state any
--- @return agentic.acp.SubagentWorkState|nil work_state
function M._parse_state(state)
    if type(state) ~= "table" or type(state.state) ~= "string" then
        return nil
    end

    local kind = KNOWN_STATES[state.state]

    --- @type agentic.acp.SubagentWorkState
    local work_state
    if not kind then
        work_state = { kind = "unrecognized", name = state.state }
    elseif kind == "idle" and type(state.stopReason) == "string" then
        work_state = { kind = kind, stop_reason = state.stopReason }
    else
        work_state = { kind = kind }
    end
    return work_state
end

return M
