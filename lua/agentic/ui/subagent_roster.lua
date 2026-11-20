--- The child sessions announced under one root session, as `subagent_update` last described them.
--- ACP RFD "Subagent Sessions": https://agentclientprotocol.com/rfds/subagents
--- @class agentic.ui.SubagentRoster
--- @field _children table<string, agentic.ui.SubagentRoster.Child>
local SubagentRoster = {}
SubagentRoster.__index = SubagentRoster

--- Replayed states are history: the RFD confirms current work only after the load response.
--- @alias agentic.ui.SubagentRoster.Observed "replay" | "live"

--- @class agentic.ui.SubagentRoster.State
--- @field work agentic.acp.SubagentWorkState
--- @field observed agentic.ui.SubagentRoster.Observed

--- @class agentic.ui.SubagentRoster.Child
--- @field title? string
--- @field description? string
--- @field state? agentic.ui.SubagentRoster.State

--- @return agentic.ui.SubagentRoster
function SubagentRoster:new()
    return setmetatable({ _children = {} }, self)
end

--- @param association agentic.acp.SubagentAssociation
--- @param replaying boolean
--- @return agentic.ui.SubagentRoster.Child child
function SubagentRoster:apply(association, replaying)
    local child = self._children[association.child_session_id] or {}

    child.title = association.title or child.title
    child.description = association.description or child.description
    if association.state then
        child.state = {
            work = association.state,
            observed = replaying and "replay" or "live",
        }
    end

    self._children[association.child_session_id] = child
    return child
end

--- @return string[] child_session_ids Children confirmed to be doing foreground work now
function SubagentRoster:working_ids()
    --- @type string[]
    local ids = {}
    for id, child in pairs(self._children) do
        local state = child.state
        if
            state
            and state.observed == "live"
            and (
                state.work.kind == "running"
                or state.work.kind == "requires_action"
            )
        then
            ids[#ids + 1] = id
        end
    end
    return ids
end

--- The tool-call status a child's block is drawn with.
--- @param child agentic.ui.SubagentRoster.Child
--- @return agentic.acp.ToolCallStatus status
function SubagentRoster.display_status(child)
    local work = child.state and child.state.work
    if not work then
        return "pending"
    end

    if work.kind == "running" then
        return "in_progress"
    end

    if work.kind == "idle" then
        local failed = work.stop_reason == "cancelled"
            or work.stop_reason == "error"
        return failed and "failed" or "completed"
    end

    return "pending"
end

return SubagentRoster
