function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.HandlesUndo = true
    finaleplugin.MinJWLuaVersion = 0.68
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.0"
    finaleplugin.Date = "October 17, 2023"
    finaleplugin.Notes = [[
        If you want to execute scripts running in Trusted mode, this console script must also be
        configured as Trusted in the RGP Lua Configuration window.
    ]]
    return "RGP Lua Console...", "RGP Lua Console", "Allows immediate editing and testing of scripts in RGP Lua."
end

require('mobdebug').start()

--global variables prevent garbage collection until script terminates and releases Lua State

if not finenv.RetainLuaState then
    context =
    {
        tabstop_width = 4,
        output_tabstop_width = 8,
        clear_output = false,
        script_text = nil,
        script_file = nil,
        output_text = nil,
        recent_files = {},
        window_pos_x = nil,
        window_pos_y = nil
    }
end

global_dialog = nil

local edit_text             -- text editor
local line_number_text      -- line mumbers
local output_text           -- print output area
local clear_output_chk      -- Clear Before Run checkbox


local function win_mac(winval, macval)
    if finenv.UI():IsOnWindows() then return winval end
    return macval
end

local function calc_tab_width(font, numchars) -- assumes fixed_width font
    local adv_points = 0
    local curr_doc = finale.FCDocument()
    if curr_doc.ID <= 0 then
        -- if no document, use hard-coded values derived from when we did have a document.
        adv_points = win_mac(4.9482421875, 6.60107421875) -- win 10pt Consolas is 5.498046875
    else
        local text_met = finale.FCTextMetrics()
        text_met:LoadString(finale.FCString("a"), font, 100)
        adv_points = text_met:GetAdvanceWidthEVPUs() / 4 -- GetAdvanceWidthPoints does not return points on Windows
    end
    return numchars * adv_points
end

local function setup_edittext_control(control, width, height, editable, tabstop_width)
    control:SetWidth(width)
    control:SetHeight(height)
    control:SetReadOnly(not editable)
    control:SetUseRichText(false)
    control:SetWordWrap(false)
    local font = win_mac(finale.FCFontInfo("Consolas", 9), finale.FCFontInfo("Monaco", 11))
    control:SetFont(font)
    if tabstop_width then
        control:SetTabstopWidth(calc_tab_width(font, tabstop_width))
    end
    return control
end

function output_to_console(...)
    local args = { ... } -- Pack all arguments into a table
    local formatted_args = {}
    for i, arg in ipairs(args) do
        formatted_args[i] = tostring(arg)                             -- Convert each argument to a string
    end
    local formatted_string = table.concat(formatted_args, "\t") .. "\n" -- Concatenate arguments with tabs
    output_text:AppendText(finale.FCString(formatted_string))
end

function on_execution_will_start(item)
    output_to_console("Running [" .. item.MenuItemText .. "] ======>")
end

function on_execution_did_stop(item, success, msg, msgtype)
    if success then
        output_to_console("<======= ["..item.MenuItemText.."] succeeded (Processing time: 0.000 s).") -- ToDo: calculate processing time.
    else
        -- script results have already been sent to ouput by RGP Lua, so skip them
        if msgtype ~= finenv.MessageResultType.SCRIPT_RESULT then
            output_to_console(msg)
            if msgtype == finenv.MessageResultType.EXTERNAL_TERMINATION then
                output_to_console("The RGP Lua Console does not support retaining Lua state or running modeless dialogs.")
            end
        end
        output_to_console("<======= ["..item.MenuItemText.."] FAILED.")
    end
end

local function run_script(control)
    control:SetEnable(false)
    local script_path = finenv.RunningLuaFolderPath() .. "/untitled.lua" -- ToDo: get actual path
    local script_text = finale.FCString()
    edit_text:GetText(script_text)
    local script_items = finenv.CreateLuaScriptItemsFromFilePath(script_path, script_text.LuaString)
    if script_items.Count > 0 then
        local script_item = script_items:GetItemAt(0)
        script_item.AutomaticallyReportErrors = false
        script_item.Debug = true
        script_item:RegisterPrintFunction(output_to_console)
        script_item:RegisterOnExecutionWillStart(on_execution_will_start)
        script_item:RegisterOnExecutionDidStop(on_execution_did_stop)
        --script_item.Trusted = true
        if clear_output_chk:GetCheck() ~= 0 then
            output_text:SetText(finale.FCString(""))
        end
        finenv.ExecuteLuaScriptItem(script_item)
        if script_item:IsExecuting() then
            script_item:StopExecuting() -- for now, no support for modeless dialogs or RetainLuaState.
        end
    end
    control:SetEnable(true) -- ToDo: leave it disabled if the script item is still running
end

local create_dialog = function()
    local dialog = finale.FCCustomLuaWindow()
    dialog:SetTitle(finale.FCString("RGP Lua - Console"))
    local x_separator = 10
    local y_separator = 10
    local curr_y = 0
    local edit_text_height = 280
    local output_height = edit_text_height / 2.5
    local line_number_width = 90
    local total_width = 960
    line_number_text = setup_edittext_control(dialog:CreateEditText(0, curr_y), line_number_width, edit_text_height, false)
    edit_text = setup_edittext_control(dialog:CreateEditText(line_number_width + x_separator, curr_y),
        total_width - line_number_width - x_separator, edit_text_height, true, context.tabstop_width)
    curr_y = curr_y + y_separator + edit_text_height
    local button_width = 100
    local button_height = 20
    local run_script_cmd = dialog:CreateButton(total_width - button_width, curr_y)
    run_script_cmd:SetText(finale.FCString("Run Script"))
    run_script_cmd:SetWidth(button_width)
    dialog:RegisterHandleControlEvent(run_script_cmd, run_script)
    curr_y = curr_y + button_height + y_separator
    local output_desc = dialog:CreateStatic(0, curr_y)
    output_desc:SetWidth(100)
    output_desc:SetText(finale.FCString("Execution Output:"))
    local clear_output_chk_width = win_mac(105, 120)
    local clear_now = dialog:CreateButton(120, curr_y - win_mac(5,1))
    clear_now:SetText(finale.FCString("Clear"))
    dialog:RegisterHandleControlEvent(clear_now, function(control)
        output_text:SetText(finale.FCString(""))
    end)
    clear_output_chk = dialog:CreateCheckbox(total_width - clear_output_chk_width, curr_y)
    clear_output_chk:SetWidth(clear_output_chk_width)
    clear_output_chk:SetText(finale.FCString("Clear Before Run"))
    curr_y = curr_y + button_height
    output_text = setup_edittext_control(dialog:CreateEditText(0, curr_y), total_width, output_height, false,
        context.output_tabstop_width)
    local ok_btn = dialog:CreateOkButton()
    ok_btn:SetText(finale.FCString("Close"))
    dialog:RegisterInitWindow(function()
        clear_output_chk:SetCheck(context.clear_output and 1 or 0)
        if context.script_text then
            edit_text:SetText(finale.FCString(context.script_text))
        end
        if context.output_text then
            output_text:SetText(finale.FCString(""))
            output_text:AppendText(finale.FCString(context.output_text)) -- AppendText scrolls to the end
        end
        edit_text:SetKeyboardFocus()
    end)
    dialog:RegisterCloseWindow(function()
        if global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_ALT) or global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
            finenv.RetainLuaState = false
        else
            finenv.RetainLuaState = true
        end
        if finenv.RetainLuaState then
            context.clear_output = clear_output_chk:GetCheck() ~= 0
            local text = finale.FCString()
            edit_text:GetText(text)
            context.script_text = text.LuaString
            output_text:GetText(text)
            context.output_text = text.LuaString
            global_dialog:StorePosition()
            context.window_pos_x = global_dialog.StoredX
            context.window_pos_y = global_dialog.StoredY
        end 
    end)
    return dialog
end

local open_dialog = function()
    global_dialog = create_dialog()
    finenv.RegisterModelessDialog(global_dialog)
    -- For some reason we need to do this here rather than in InitWindow.
    if context.window_pos_x and context.window_pos_y then
        global_dialog:StorePosition()
        global_dialog:SetRestorePositionOnlyData(context.window_pos_x, context.window_pos_y)
        global_dialog:RestorePosition()
    end
    global_dialog:ShowModeless()
end

open_dialog()
