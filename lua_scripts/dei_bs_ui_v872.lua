return function()
    local scripting = require "lua_scripts.EpisodicScripting"
    local generation = _G.BLOODLESS_STANDALONE_GENERATION
    local BUTTON = "dei_bs_recommend_surrender_probe"
    local TIMER = "dei_bs_v87_show_probe_button"
    local panel_open, attempts, clicks = false, 0, 0
    local log_started = false
    local function log(message)
        -- Distribution build: diagnostic output disabled.
    end
    local function id(context)
        local ok, value = pcall(function()return context.string end)
        return ok and tostring(value) or ""
    end
    local function find(name)
        local ok, result = pcall(function()
            if not scripting.m_root then return nil end
            local ptr = scripting.m_root:Find(name)
            if ptr then return UIComponent(ptr) end
        end)
        if ok then return result end
    end
    local function later()
        scripting.game_interface:add_time_trigger(TIMER,0.15)
    end
    local function tooltip()
        return "Demand Surrender"
    end
    local function show()
        if not panel_open then return end
        local land=find(BUTTON)
        local fleet=find("dei_bs_recommend_surrender_fleet")
        local ok,valid=pcall(function()
            local pb=scripting.game_interface:model():pending_battle()
            return pb:is_active() and pb:has_attacker() and pb:has_contested_garrison()
                and pb:attacker():faction():is_human()
        end)
        local function visible(name)
            local c=find(name)
            if not c then return false end
            local success,result=pcall(function()return c:Visible()end)
            return success and result
        end
        local native,button
        if ok and valid then
            if visible("button_set_attack") and visible("button_maintain_blockade") then
                native="button_maintain_blockade";button=fleet
            elseif visible("button_set_siege") then
                for _,name in ipairs({"button_continue_siege","button_surround"}) do
                    if visible(name) then native=name;button=land;break end
                end
            end
        end
        for _,c in pairs({land=land,fleet=fleet}) do
            if c~=button then pcall(function()c:SetVisible(false)end)end
        end
        if not button then
            attempts=attempts+1
            if attempts<=10 then later()
            else log("NOT SHOWN: valid_settlement="..tostring(ok and valid).." native="..tostring(native).." land="..tostring(land~=nil).." fleet="..tostring(fleet~=nil))end
            return
        end
        local success,err=pcall(function()
            button:SetVisible(true);button:SetDisabled(false);button:SetInteractive(true)
            button:SetState("active");button:SetTooltipText("Demand surrender||If your forces are powerful enough you can try to demand a surrender.||If the enemy accepts you will be spared a lengthy wait or a bloody battle and losses on both sides.")
        end)
        log("SHOW "..tostring(success).." native="..tostring(native).." detail="..tostring(err))
    end
    local function register(event, callback)
        scripting.AddEventCallBack(event,function(context)
            if generation==_G.BLOODLESS_STANDALONE_GENERATION then callback(context)end
        end)
    end
    register("PanelOpenedCampaign",function(context)
        if id(context)=="popup_pre_battle" then
            panel_open=true;attempts=0;clicks=0
            log("PREBATTLE OPEN; request button display")
            later()
        end
    end)
    register("PanelClosedCampaign",function(context)
        if id(context)=="popup_pre_battle" then panel_open=false end
    end)
    register("TimeTrigger",function(context)if id(context)==TIMER then show()end end)
    log("INSTALLED: surrender request button; V8.7.6 integration")
end
