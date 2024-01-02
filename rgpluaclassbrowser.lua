function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.MinJWLuaVersion = 0.56
    finaleplugin.LoadLuaOSUtils = true
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "2.0"
    finaleplugin.Date = "December 27, 2023"
    finaleplugin.Notes = [[
        This script uses the built-in reflection of PDK Framework classes in RGP Lua to display all
        the framework classes and their methods and properties. Use the edit text boxes at the top
        to filter the classes and methods you are interested in. It also displays inherited methods and
        properties with an asterisk (and shows which base class they come from). Clicking one of the documentation
        links opens the documentation page for that item in a browser window.

        For the documentation links to work properly and to display the correct function signatures, you need the
        jwluatagfile.xml file that matches the version of RGP Lua you are using. You can obtain the latest versions
        of RGP Lua, this script, and the corresponding jwluatagfile.xml from the download link:
        
        https://robertgpatterson.com/-fininfo/-rgplua/rgplua.html
        
        For other versions, visit the Github repository:
        
        https://github.com/finale-lua/rgpluaclassbrowser

        Normally the class browser only builds the class index once (since doing so takes several seconds).
        It then retains its Lua state so that all future calls inherits the same class index. If there is a Lua
        error or some other issue, you may wish to rebuild the index. In that case, click the "Close" button while
        holding down either the Shift key or the Option key (Mac) or Alt key (Windows). It will then open the next
        time with a fresh Lua state and rebuild the class index.
    ]]
    return "RGP Lua Class Browser...", "RGP Lua Class Browser", "Explore the PDK Framework classes in RGP Lua."
end

--global variables prevent garbage collection until script terminates and releases Lua State

if not finenv.RetainLuaState then
    luaosutils = nil
    if finenv.MajorVersion > 0 or finenv.MinorVersion >= 0.66 then
        luaosutils = require('luaosutils')    
    end
    documentation_sites =
    {
        finale = "https://pdk.finalelua.com/",
        finenv = "https://robertgpatterson.com/-fininfo/-rgplua/docs/rgp-lua/finenv-properties.html",
        tinyxml2 = "http://leethomason.github.io/tinyxml2/"
    }
    eligible_classes = {}
    global_class_index = nil
    context = 
    {
        filter_classes_text = nil,
        classes_index = nil,
        filter_properties_text = nil,
        properties_index = nil,
        filter_methods_text = nil,
        methods_index = nil,
        class_methods_index = nil,
        window_pos_x = nil,
        window_pos_y = nil
    }
end

global_dialog = nil
global_dialog_info = {}     -- key: list control id or hard-coded string, value: table of associated data and controls
global_control_xref = {}    -- key: non-list control id, value: associated list control id
global_timer_id = 1         -- per docs, we supply the timer id, starting at 1
global_popup_timer_id = 2   -- this is used on Windows to create a popup window, since FX_Dialog cannot do it from WM_KEYDOWN
global_list_box = nil       -- this is used to store the list control for the popup window, since FX_Dialog cannot do it from WM_KEYDOWN
global_progress_label = nil
global_metadata_available = false

current_class_name = ""
changing_class_name_in_progress = false

function table_merge (t1, t2)
    for k, v in pairs(t2) do
        if nil == t1[k] then
            t1[k] = v
        end
    end 
    return t1
end

local function win_mac(winval, macval)
    if finenv.UI():IsOnWindows() then return winval end
    return macval
end

function get_edit_text(edit_control)
    if not edit_control then return "" end
    local fcstring = finale.FCString()
    edit_control:GetText(fcstring)
    return fcstring.LuaString
end

function set_text(control, text, setter_name)
    if not control then return end
    setter_name = setter_name or "SetText"
    local fcstring = finale.FCString()
    fcstring.LuaString = text or ""
    control[setter_name](control, fcstring)
end

function set_list_selected_item(list_control, index, selection_func)
    if index >= 0 and list_control:GetCount() > index then
        list_control:SetSelectedItem(index)
        if finenv.UI():IsOnWindows() and type(selection_func) == "function" then
            selection_func(list_control, index)
        end
    end
end
    
function method_info(class_info, method_name)
    local rettype, args
    if class_info then
        local method = class_info.__members[method_name]
        if method then
            args = method.arglist and method.arglist:gsub(" override", "")
            rettype = method.type and method.type:gsub("virtual ", "")
            rettype = rettype and rettype:gsub("static ", "")
        end
    end
    return rettype, args
end

function get_namespace_table(namespace)
    if namespace:find(".") then
        local parts = {}
        for part in namespace:gmatch("[^.]+") do
            table.insert(parts, part)
        end
        local currentTable = _G
        for _, part in ipairs(parts) do
            currentTable = currentTable[part]
            if not currentTable then
                break
            end
        end            
        return currentTable        
    end
    return _G[namespace]
end

function get_properties_methods(classname)
    assert(type(classname) == "string", "string expected for argument 1, got " .. type(classname))
    if classname == "" then return nil end
    isparent = isparent or false
    local properties = {}
    local methods = {}
    local class_methods = {}
    local namespace = eligible_classes[classname]
    namespace = namespace or "finale"
    assert(type(namespace) == "string", "namespace " .. tostring(namespace) .. " is not a string")
    local classtable = classname ~= namespace and _G[namespace][classname] or get_namespace_table(namespace)
    assert(type(classtable) == "table", namespace .. "." .. classname .. " is not a table")
    local class_info = global_class_index[classname]
    local function get_metadata(v)
        -- versions before RGP Lua 0.70 return a meaningless string
        if type(v) == "table" then
            if not global_metadata_available then
                global_metadata_available = true
            end
            return v
        end
        return {false, ""}
    end
    if classtable.__class then
        for k, v in pairs(classtable.__class) do
            local metadata = get_metadata(v)
            local rettype, args = method_info(class_info, k)
            methods[k] = { class = classname, arglist = args, returns = rettype, deprecated = metadata[1], first_avail = metadata[2]}
        end
    end
    if classtable.__propget then
        for k, v in pairs(classtable.__propget) do
            local metadata = get_metadata(v)
            local rettype
            if namespace == classname then
                if class_info then
                    rettype = method_info(global_class_index[class_info[k]], k)
                end
                rettype = rettype or type(get_namespace_table(namespace)[k])
            end
            properties[k] = { class = classname, readable = true, writeable = false, returns = rettype, deprecated = metadata[1], first_avail = metadata[2]}
        end
    end
    if classtable.__propset then
        for k, v in pairs(classtable.__propset) do
            if nil == properties[k] then
                local metadata = get_metadata(v)
                properties[k] = { class = classname, readable = false, writeable = true, deprecated = metadata[1], first_avail = metadata[2]}
            else
                properties[k].writeable = true
            end
        end
    end
    if classtable.__static then
        for k, v in pairs(classtable.__static) do
            local metadata = get_metadata(v)
            local rettype, args = method_info(class_info, k)
            class_methods[k] = { class = classname, arglist = args, returns = rettype, deprecated = metadata[1], first_avail = metadata[2]}
        end
    end
    if classtable.__parent then
        for k, _ in pairs(classtable.__parent) do
            local parent_methods, parent_properties = get_properties_methods(k)
            if type(parent_methods) == "table" then
                methods = table_merge(methods, parent_methods)
            end
            if type(parent_properties) == "table" then
                properties = table_merge(properties, parent_properties)
            end
        end
    end
    return methods, properties, class_methods
end

function update_list(list_control, source_table, search_text)
    list_control:Clear()
    search_text = search_text or ""
    local include_all = search_text == ""
    local search_case_lower = string.lower(search_text)
    local first_string = nil
    if type(source_table) == "table" then
        for k, v in pairsbykeys(source_table) do
            if include_all or string.find(string.lower(k), search_case_lower) then
                local fcstring = finale.FCString()
                fcstring.LuaString = k
                if type(v) == "table" then
                    if v.class ~= current_class_name then
                        fcstring.LuaString = fcstring.LuaString .. "  *"
                    end
                    if v.readable or v.writeable then
                        local str = "  ["
                        if v.readable then
                            str = str .. "R"
                            if v.writeable then
                                str = str .. "/W"
                            end
                        elseif v.writeable then
                            str = str .. "W"
                        end
                        str = str .. "]"
                        fcstring.LuaString = fcstring.LuaString .. str
                    end
                    if v.deprecated then
                        fcstring.LuaString = fcstring.LuaString .. " ⚠️"
                    end
                end
                list_control:AddString(fcstring)
                if first_string == nil then
                    first_string = k
                end
            end
        end
    end
    if finenv.UI():IsOnWindows() then
        set_list_selected_item(list_control, 0)
    end
    return first_string
end

local on_list_select = function(list_control)
    local list_info = global_dialog_info[list_control:GetControlID()]
    if list_info and list_info.selection_function and not list_info.in_progress then
        local selected_item = list_info.list_box:GetSelectedItem()
        if list_info.current_index ~= selected_item then
            list_info.in_progress = true
            list_info.current_index = selected_item
            list_info.selection_function(list_info.list_box, selected_item)
            list_info.in_progress = false
        end
    end
end

function on_classname_changed(new_classname)
    if changing_class_name_in_progress then return end
    changing_class_name_in_progress = true
    current_class_name = new_classname
    local name_for_display = current_class_name
    local namespace = eligible_classes[new_classname]
    if namespace then
        if namespace ~= name_for_display then
            name_for_display = namespace.."."..name_for_display
        end
        local classtable = _G[namespace] and _G[namespace][current_class_name]
        if type(classtable) == "table" and classtable.__parent then
            for k, _ in pairs(classtable.__parent) do
                name_for_display = name_for_display.." : "..k
            end
        end
    end
    set_text(global_progress_label, name_for_display)
    local current_methods, current_properties, current_class_methods = get_properties_methods(new_classname)
    global_dialog_info[global_control_xref["properties"]].current_strings = current_properties
    global_dialog_info[global_control_xref["methods"]].current_strings = current_methods
    global_dialog_info[global_control_xref["class_methods"]].current_strings = current_class_methods
    for k, v in pairs({"properties", "methods", "class_methods"}) do
        local list_info = global_dialog_info[global_control_xref[v]]
        update_list(list_info.list_box, list_info.current_strings, get_edit_text(list_info.search_text))
        if finenv.UI():IsOnWindows() then
            on_method_selection(list_info.list_box, list_info.list_box:GetSelectedItem())
        end
    end
    changing_class_name_in_progress = false
end

function on_class_selection(list_control, index)
    if index < 0 then
        on_classname_changed("")
        return
    end
    local str = get_plain_string(list_control, index)
    if str ~= current_class_name then
        on_classname_changed(str)
    end
end

function hide_show_display_area(list_info, show)
    list_info.fullname_static:SetVisible(show)
    list_info.returns_label:SetVisible(show and get_edit_text(list_info.returns_static) ~= "")
    list_info.returns_static:SetVisible(show and get_edit_text(list_info.returns_static) ~= "")
    list_info.method_doc_button:SetVisible(show)
    if list_info.arglist_static then
        list_info.arglist_label:SetVisible(show and get_edit_text(list_info.arglist_static) ~= "")
        list_info.arglist_static:SetVisible(show and get_edit_text(list_info.arglist_static) ~= "")
    end
    if global_metadata_available then
        list_info.first_avail_label:SetVisible(show)
        list_info.first_avail:SetVisible(show)
    end
    list_info.method_copy_button:SetVisible(show)
    list_info.show_deprecated:SetVisible(show)
end

function get_plain_string(list_control, index)
    local fcstring = finale.FCString()
    if index >= 0 then
        list_control:GetItemText(index, fcstring)
    end
    return string.match(fcstring.LuaString, "%S+")
end

function on_method_selection(list_control, index)
    local list_info = global_dialog_info[list_control:GetControlID()]
    local is_class_methods = global_control_xref["class_methods"] == list_control:GetControlID()
    local show = false
    if list_info and index >= 0 then
        local method_name = get_plain_string(list_control, index)
        if #method_name > 0 and list_info.current_strings then
            local method_info = list_info.current_strings[method_name]
            if method_info then
                local dot = (list_info.is_property or is_class_methods) and "." or ":"
                set_text(list_info.fullname_static, method_info.class .. dot .. method_name)
                set_text(list_info.show_deprecated, method_info.deprecated and "**deprecated**" or "")
                if global_metadata_available then
                    set_text(list_info.first_avail, #method_info.first_avail > 0 and method_info.first_avail or "JW Lua")
                end
                if list_info.is_property then
                    local methods_list_info = global_dialog_info[global_control_xref["methods"]]
                    local property_getter_info = methods_list_info.current_strings["Get" .. method_name]
                        or methods_list_info.current_strings[method_name]
                    if property_getter_info then
                        method_info = property_getter_info
                    end
                    set_text(list_info.returns_static, method_info.returns)
                else
                    set_text(list_info.returns_static, method_info.returns)
                    set_text(list_info.arglist_static, method_info.arglist)
                end
                if get_edit_text(list_info.fullname_static) ~= "" then
                    show = true
                end
            end
        end
    end
    hide_show_display_area(list_info, show)
end

function update_classlist()
    local list_id = global_control_xref["classes"]
    if nil == list_id then return end
    local list_info = global_dialog_info[list_id]
    if list_info then
        local search_text = get_edit_text(list_info.search_text)
        if search_text == list_info.current_search_text then return end
        list_info.current_search_text = search_text
        search_text = search_text or ""
        local first_string = update_list(list_info.list_box, eligible_classes, search_text)
        if finenv.UI():IsOnWindows() then
            local index = list_info.list_box:GetSelectedItem()
            if index >= 0 then
                on_class_selection(list_info.list_box, index)
            else
                on_classname_changed("")
            end
        end
    end
end

function launch_docsite(namespace, html_file, anchor)
    local doc_site = documentation_sites[namespace]
    if type(doc_site) ~= "string" then
        error("no documentation site provided for namespace "..tostring(namespace), 2)
    end
    local url = doc_site
    if html_file then
        url = url .. html_file
        if anchor then
            url = url .. "#" .. anchor
        end
    end
    if luaosutils and luaosutils.internet.launch_website then
        luaosutils.internet.launch_website(url)
    else
        if finenv.UI():IsOnWindows() then
            url = "start " .. url
        else
            url = "open " .. url
        end
        os.execute(url)
    end
end

function on_doc_button(button_control)
    local list_info = global_dialog_info[global_control_xref[button_control:GetControlID()]]
    if list_info then
        local index = list_info.list_box:GetSelectedItem()
        local method_name = get_plain_string(list_info.list_box, index)
        if #method_name > 0 then
            local method_info = list_info.current_strings[method_name]
            if method_info then
                local class_info = (function()
                    if eligible_classes[method_info.class] == method_info.class then
                        local class_name_xref = global_class_index[method_info.class]
                        if class_name_xref then
                            return global_class_index[class_name_xref[method_name]]
                        end
                        return nil
                    end
                    return global_class_index[method_info.class]
                end)()
                if class_info then
                    local method_metadata = class_info.__members[method_name]
                    if not method_metadata and list_info.is_property then
                        method_metadata = class_info.__members
                            ["Get" .. method_name] -- use property getter for properties
                    end
                    local filename = class_info.filename
                    local anchor = nil
                    if method_metadata then
                        anchor = method_metadata.anchor
                        if method_metadata.anchorfile then
                            filename = method_metadata.anchorfile
                        end
                    end
                    launch_docsite(class_info.namespace, filename, anchor)
                elseif eligible_classes[method_info.class] == method_info.class then
                    -- just launch to the base site if no information about constant property
                    -- (mainly this is tinyxml2 constants)
                    launch_docsite(method_info.class)
                end
            end
        end
    end
end

local function get_full_method_name(list_box_id, method_name)
    local retval = method_name
    local namespace = eligible_classes[current_class_name]
    if list_box_id == global_control_xref["classes"] then
        if namespace ~= retval then
            retval = namespace .. "." .. retval
        end
    elseif list_box_id == global_control_xref["class_methods"] then
        retval = current_class_name .. "." .. retval
        if namespace ~= current_class_name then
            retval = namespace .. "." .. retval
        end
    elseif list_box_id == global_control_xref["properties"] then
        if current_class_name == namespace then
            retval = current_class_name .. "." .. retval
        end
    end
    return retval
end

function on_copy(control)
    local list_box_id = (function()
        if control:ClassName() == "FCCtrlListBox" then
            return control:GetControlID()
        end
        return global_control_xref[control:GetControlID()]
    end)()
    assert(type(list_box_id) == "number", control:ClassName() .. " control id " .. control:GetControlID() .. " not found")
    local list_info = global_dialog_info[list_box_id]
    assert(list_info, "invalid list_box_id: " .. list_box_id)
    local index = list_info.list_box:GetSelectedItem()
    local method_name = get_full_method_name(list_box_id, get_plain_string(list_info.list_box, index))
    finenv.UI():TextToClipboard(method_name)
end

function on_item_selected(control)
    local total_width = 400
    local list_box_id = control:GetControlID()
    local list_info = global_dialog_info[list_box_id]
    assert(list_info, "invalid list_box_id: " .. list_box_id)
    local index = list_info.list_box:GetSelectedItem()
    local method_name = get_plain_string(list_info.list_box, index)
    local full_method_name = get_full_method_name(list_box_id, method_name)
    local dialog = finale.FCCustomWindow()
    set_text(dialog, "Details", "SetTitle")
    local show_method_name = dialog:CreateEdit(0, 0)
    show_method_name:SetWidth(total_width)
    set_text(show_method_name, full_method_name)
    local namespace = eligible_classes[current_class_name]
    local y = 30
    local y_increment = 16
    local x_increment = 5
    local r_column = 75
    local is_class = list_box_id == global_control_xref["classes"]
    local method_info = not is_class and list_info.current_strings[method_name]
    local classtable = get_namespace_table(namespace)[method_info and method_info.class or current_class_name]
    local base_class = ""
    if type(classtable) == "table" and classtable.__parent then
        for k, _ in pairs(classtable.__parent) do
            base_class = k
            break
        end
    end
    local function create_item(label, value)
        local label_control = dialog:CreateStatic(0, y)
        label_control:SetWidth(r_column - x_increment)
        set_text(label_control, label)
        local value_control = dialog:CreateStatic(r_column, y)
        value_control:SetWidth(total_width - r_column)
        set_text(value_control, value)
        y = y + y_increment
    end
    if method_info then
        local class_desc = method_info.class
        if #base_class > 0 then
            class_desc = class_desc .. " : " .. base_class
        end
        local label_desc = method_info.class == namespace and "Namespace:" or "Class:"
        create_item(label_desc, class_desc)
    else
        create_item("Base Class:", base_class)
    end
    if method_info then
        if list_info.is_property then
            local methods_list_info = global_dialog_info[global_control_xref["methods"]]
            local property_getter_info = methods_list_info.current_strings["Get" .. method_name]
                or methods_list_info.current_strings[method_name]
            if property_getter_info then
                method_info = property_getter_info
            end
            create_item("Type:", method_info.returns)
        else
            create_item("Returns:", method_info.returns)
            create_item("Arguments:", method_info.arglist)
        end
        if global_metadata_available then
            local meta_desc = #method_info.first_avail > 0 and method_info.first_avail or "JW Lua"
            if method_info.deprecated then
                meta_desc = meta_desc .. " **deprecated**"
            end
            create_item("Available:", meta_desc)
        end
    end
    dialog:CreateOkButton()
    dialog:ExecuteModal(global_dialog)
end

get_eligible_classes = function()
    set_text(global_progress_label, "Getting eligible classes from Lua state...")
    local retval = {}
    local function process_namespace(namespace, startswith)
        if not _G[namespace] then return end
        retval[namespace] = namespace
        for k, v in pairs(_G[namespace]) do
            if type(k) == "string" and k:find("_") ~= 1 then
                if #startswith > 0 and k:find(startswith) == 1 then
                    retval[k] = namespace
                end
            end
        end
    end
    process_namespace("finale", "FC")
    process_namespace("finenv", "")
    for k, v in pairs(finenv) do
        if type(k) == "string" and k:find("_") ~= 1 and type(v) == "table" then
            local nested_namespace = "finenv." .. k
            retval[nested_namespace] = nested_namespace
            documentation_sites[nested_namespace] = documentation_sites["finenv"]
        end
    end
    process_namespace("tinyxml2", "XML")
    return retval
end

create_class_index_xml = function()
    local xml = tinyxml2.XMLDocument()
    local result = xml:LoadFile(finenv.RunningLuaFolderPath() .. "/jwluatagfile.xml")
    if result ~= tinyxml2.XML_SUCCESS then
        error("Unable to find jwluatagfile.xml. Is it in the same folder with this script?")
    end
    local class_collection = {}
    class_collection.finale = {} -- cross reference from namespace to class for namespace constants
    local tagfile = tinyxml2.XMLHandle(xml):FirstChildElement("tagfile"):ToNode()
    for compound in xmlelements(tagfile, "compound") do
        if compound:Attribute("kind", "class") then
            local class_info = { _attr = { kind = 'class' }, __members = {} }
            class_info.name = compound:FirstChildElement("name"):GetText()
            class_info.namespace = "finale"
            class_info.filename = compound:FirstChildElement("filename"):GetText()
            local base_element = compound:FirstChildElement("base")
            class_info.base = base_element and base_element:GetText() or nil
            for member in xmlelements(compound, "member") do
                local kind_attr = member:Attribute("kind")
                if kind_attr then
                    local member_info = { _attr = { kind = kind_attr } }
                    local type_element =  member:FirstChildElement("type")
                    member_info.type = type_element and type_element:GetText() or kind_attr
                    member_info.name = member:FirstChildElement("name"):GetText()
                    member_info.anchorfile = member:FirstChildElement("anchorfile"):GetText()
                    member_info.anchor = member:FirstChildElement("anchor"):GetText()
                    if kind_attr == "function" then
                        member_info._attr.protection = member:Attribute("protection")
                        member_info._attr.static = member:Attribute("static")
                        member_info._attr.virtualness = member:Attribute("virtualness")
                        member_info.arglist = member:FirstChildElement("arglist"):GetText()
                    end
                    if kind_attr ~= "function" then
                        -- cross reference to get back to the member info from the constant name
                        class_collection.finale[member_info.name] = class_info.name
                    end
                    class_info.__members[member_info.name] = member_info
                end
            end
            class_collection[class_info.name] = class_info
        end
    end
    xml:Clear()
    return class_collection
end

add_xml_classes_to_index = function(class_collection)
    if tinyxml2 then
        for k, _ in pairs(tinyxml2) do
            kstr = tostring(k)
            if kstr:find("XML") == 1 then
                local class_info = { _attr = { kind = 'class' }, __members = {} }
                class_info.name = kstr
                class_info.namespace = "tinyxml2"
                class_info.filename = "classtinyxml2_1_1_x_m_l_" .. kstr:sub(4):lower() .. ".html"
                class_collection[class_info.name] = class_info
                -- no hard-coded method anchors: too unreliable
            end
        end
    end
end

create_class_index_str = function()
    local file, e = io.open(finenv.RunningLuaFolderPath() .. "/jwluatagfile.xml", 'r')
    if not file then
        error("Unable to find jwluatagfile.xml. Is it in the same folder with this script?")
    end
    if io.type(file) ~= 'file' then
        finenv.UI():AlertError(e, nil)
    end
    local xml = file:read('*a')
    file:close()
    local class_collection = {}
    class_collection.finale = {} -- cross reference from namespace to class for namespace constants
    for class_block in string.gmatch(xml, '<compound kind=%"class%">.-</compound>') do
        local class_info = { _attr = { kind = 'class' }, __members = {} }
        class_info.name = string.match(class_block, '<name>(.-)</name>')
        class_info.namespace = "finale"
        class_info.filename = string.match(class_block, '<filename>(.-)</filename>')
        class_info.base = string.match(class_block, '<base>(.-)</base>')
        for member_block in string.gmatch(class_block, '<member.-</member>') do
            local kind = string.match(member_block, 'kind=%"(%w+)%"')
            if kind then
                local member_info = { _attr = { kind = kind } }
                local type_element = string.match(member_block, '<type>(.-)</type>')
                member_info.type = type_element or kind
                member_info.name = string.match(member_block, '<name>(.-)</name>')
                member_info.anchorfile = string.match(member_block, '<anchorfile>(.-)</anchorfile>')
                member_info.anchor = string.match(member_block, '<anchor>(.-)</anchor>')
                if kind == "function" then
                    member_info._attr.protection = string.match(member_block, 'protection=%"(%w+)%"')
                    member_info._attr.static = string.match(member_block, 'static=%"(%w+)%"')
                    member_info._attr.virtualness = string.match(member_block, 'virtualness=%"(%w+)%"')
                    member_info.arglist = string.match(member_block, '<arglist>(%([^\n]*%)%s*.-)</arglist>')
                end
                if kind ~= "function" then
                    class_collection.finale[member_info.name] = class_info.name
                end
                class_info.__members[member_info.name] = member_info
            end
        end
        class_collection[class_info.name] = class_info
    end
    return class_collection
end

coroutine_build_class_index = coroutine.create(function()
        if not finenv.RetainLuaState then
            eligible_classes = get_eligible_classes()
            coroutine.yield()
            global_class_index = tinyxml2 and create_class_index_xml() or create_class_index_str()
            add_xml_classes_to_index(global_class_index)
            -- if our coroutine aborts (due to user closing the window), we will start from scratch with a new Lua state,
            -- up until we reach this statement:
            finenv.RetainLuaState = true
        end
    end)

function on_timer(timer_id)
    if timer_id == global_popup_timer_id then
        global_dialog:StopTimer(timer_id)
        on_item_selected(global_list_box)
        global_list_box = nil
        return
    end
    if timer_id ~= global_timer_id then return end
    local success, errmsg = coroutine.resume(coroutine_build_class_index)
    if coroutine.status(coroutine_build_class_index) == "dead" then
        global_timer_id = 0 -- blocks further calls to this function
        global_dialog:StopTimer(timer_id)
        if not success then
            error(errmsg)
        end
        set_text(global_progress_label, "")
        update_classlist()
        if nil ~= context.classes_index then
            local list_info = global_dialog_info[global_control_xref["classes"]]
            set_list_selected_item(list_info.list_box, context.classes_index, on_class_selection)
            list_info = global_dialog_info[global_control_xref["properties"]]
            set_list_selected_item(list_info.list_box, context.properties_index, on_method_selection)
            list_info = global_dialog_info[global_control_xref["methods"]]
            set_list_selected_item(list_info.list_box, context.methods_index, on_method_selection)
            if context.class_methods_index and context.class_methods_index >= 0 then
                list_info = global_dialog_info[global_control_xref["class_methods"]]
                set_list_selected_item(list_info.list_box, context.class_methods_index, on_method_selection)
            end
        end
    end
end

function on_close()
    if global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_ALT) or global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
        finenv.RetainLuaState = false
    end
    if finenv.RetainLuaState then
        local list_info = global_dialog_info[global_control_xref["classes"]]
        context.filter_classes_text = get_edit_text(list_info.search_text)
        context.classes_index = list_info.list_box:GetSelectedItem()
        list_info = global_dialog_info[global_control_xref["properties"]]
        context.filter_properties_text = get_edit_text(list_info.search_text)
        context.properties_index = list_info.list_box:GetSelectedItem()
        list_info = global_dialog_info[global_control_xref["methods"]]
        context.filter_methods_text = get_edit_text(list_info.search_text)
        context.methods_index = list_info.list_box:GetSelectedItem()
        list_info = global_dialog_info[global_control_xref["class_methods"]]
        context.class_methods_index = list_info.list_box:GetSelectedItem()
        global_dialog:StorePosition()
        context.window_pos_x = global_dialog.StoredX
        context.window_pos_y = global_dialog.StoredY
    end
end

local create_dialog = function()
    local y = 0
    local vert_sep = 25
    local x = 0
    local col_width = 160
    local col_extra = 70
    local sep_width = 25
    
    local create_edit = function(dialog, this_col_width, search_func)
        local edit_text = dialog:CreateEdit(x, y)
        edit_text:SetWidth(this_col_width)
        if search_func then
            dialog:RegisterHandleControlEvent(edit_text, search_func)
        end
        
        return edit_text
    end
    
    local create_static = function(dialog, text, this_col_width)
        local static_text = dialog:CreateStatic(x, y)
        static_text:SetWidth(this_col_width)
        set_text(static_text, text)
        return static_text
    end
    
    local create_list = function(dialog, height, this_col_width, sel_func)
        local list = dialog:CreateListBox(x, y)
        list:SetWidth(this_col_width)
        list:SetHeight(height)
        if finenv.UI():IsOnMac() then
            if list.SetAlternatingBackgroundRowColors then -- property is available in this RGP Lua version
                list.AlternatingBackgroundRowColors = true
            else
                list:UseAlternatingBackgroundRowColors() -- use deprecated function if property not available
            end
        end
        return list
    end
    
    local create_column = function(dialog, height, width, static_text, sel_func, initial_text, search_func)
        y = 0
        local edit_text = nil
        if search_func then
            edit_text = create_edit(dialog, width, search_func)
            if type(initial_text) == "string" then
                set_text(edit_text, initial_text)
            end
        end
        y = y + vert_sep
        create_static(dialog, static_text, width)
        y = y + vert_sep
        local list_control = create_list(dialog, height, width, sel_func)
        global_dialog_info[list_control:GetControlID()] =
        {
            list_box = list_control,
            search_text = edit_text,
            current_search_text = nil,
            is_property = false,
            fullname_static = nil,
            returns_label = nil,
            returns_static = nil,
            arglist_label = nil,
            arglist_static = nil,
            first_avail_label = nil,
            first_avail = nil,
            show_deprecated = nil,
            method_doc_button = nil,
            method_copy_button = nil,
            selection_function = sel_func,
            current_index = -1,
            in_progress = false,
            current_strings = {}
        }
        if edit_text then
            global_control_xref[edit_text:GetControlID()] = list_control:GetControlID()
        end
        y = y + vert_sep/2 + height -- position y for adding more fields
        return list_control
    end
    
    local create_display_area = function(dialog, list_info, width, is_for_properties)
        is_for_properties = is_for_properties or false
        list_info.is_property = is_for_properties
        list_info.fullname_static = dialog:CreateStatic(x, y)
        list_info.fullname_static:SetWidth(width)
        list_info.fullname_static:SetVisible(false)
        local my_vert_sep = 15
        y = y + my_vert_sep + 5 -- more vert_sep for next info
        local my_x = x
        list_info.returns_label = dialog:CreateStatic(my_x, y)
        if is_for_properties then
            set_text(list_info.returns_label, "Type:")
        else
            set_text(list_info.returns_label, "Returns:")
        end
        local label_width = 35
        if not is_for_properties then
            label_width = 48
        end
        local doc_button_width = 40
        local my_x_sep = 1
        local return_static_width = width - label_width - doc_button_width - (2*my_x_sep)
        list_info.returns_label:SetWidth(label_width)
        list_info.returns_label:SetVisible(false)
        my_x = my_x + label_width + my_x_sep
        list_info.returns_static = dialog:CreateStatic(my_x, y)
        list_info.returns_static:SetWidth(return_static_width)
        list_info.returns_static:SetVisible(false)
        my_x = my_x + return_static_width + my_x_sep
        list_info.method_doc_button = dialog:CreateButton(my_x, y - win_mac(5,1))
        list_info.method_doc_button:SetWidth(doc_button_width)
        list_info.method_doc_button:SetVisible(false)
        global_control_xref[list_info.method_doc_button:GetControlID()] = list_info.list_box:GetControlID()
        set_text(list_info.method_doc_button, "Doc.")
        list_info.method_doc_button:SetVisible(false)
        dialog:RegisterHandleControlEvent(list_info.method_doc_button, on_doc_button)
        if not is_for_properties then
            y = y + my_vert_sep
            my_x = x
            list_info.arglist_label = dialog:CreateStatic(my_x, y)
            set_text(list_info.arglist_label, "Params:")
            list_info.arglist_label:SetWidth(label_width)
            list_info.arglist_label:SetVisible(false)
            my_x = my_x + label_width + my_x_sep
            list_info.arglist_static = dialog:CreateStatic(my_x, y)
            list_info.arglist_static:SetWidth(width - doc_button_width - my_x + x)
            list_info.arglist_static:SetVisible(false)
        else
            y = y + my_vert_sep -- get even on all columns
        end
        y = y + my_vert_sep + 5
        my_x = x
        list_info.first_avail_label = dialog:CreateStatic(my_x, y)
        set_text(list_info.first_avail_label, "First Available:")
        list_info.first_avail_label:SetWidth(85)
        list_info.first_avail_label:SetVisible(false)
        my_x = my_x + 85 + my_x_sep
        list_info.first_avail = dialog:CreateStatic(my_x, y)
        list_info.first_avail:SetWidth(width - doc_button_width - my_x - my_x_sep + x)
        list_info.first_avail:SetVisible(false)
        -- right justified button
        list_info.method_copy_button = dialog:CreateButton(x + width - doc_button_width, y - win_mac(5,1))
        list_info.method_copy_button:SetWidth(doc_button_width)
        list_info.method_copy_button:SetVisible(false)
        global_control_xref[list_info.method_copy_button:GetControlID()] = list_info.list_box:GetControlID()
        set_text(list_info.method_copy_button, "Copy")
        list_info.method_copy_button:SetVisible(false)
        dialog:RegisterHandleControlEvent(list_info.method_copy_button, on_copy)
        y = y + my_vert_sep
        my_x = x
        list_info.show_deprecated = dialog:CreateStatic(my_x, y)
        list_info.show_deprecated:SetWidth(85)
        list_info.show_deprecated:SetVisible(false)
    end
    
    local handle_edit_control = function(control)
        if 0 ~= global_timer_id then return end
        local list_id = global_control_xref[control:GetControlID()]
        if nil == list_id then return end
        local list_info = global_dialog_info[list_id]
        if list_info then
            local new_edit_text = get_edit_text(control)
            if new_edit_text ~= list_info.current_search_text then
                list_info.current_search_text = new_edit_text
                update_list(list_info.list_box, list_info.current_strings, new_edit_text)
            end
        end
    end

    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    set_text(dialog, "RGP Lua - Class Browser", "SetTitle")
    dialog:RegisterHandleCommand(on_list_select)
    --[[
    -- normally we would just use RegisterInitWindow to populate a modeless dialog,
    -- but this dialog takes a long time to process jwluatagfile.xml so we do it
    -- it in a timer handler allowing us to show progress. The UI is blocked while it happens,
    -- mainly because the xml has to be processed in one go.
    dialog:RegisterInitWindow(update_classlist)
    ]]
    dialog:RegisterInitWindow(
        function()
            global_dialog:SetTimer(global_timer_id, 1) -- timer can't be set until window is created
        end
    )
    dialog:RegisterHandleTimer(on_timer)
    
    local classes_list = create_column(dialog, 400, col_width, "Classes:", on_class_selection, context.filter_classes_text,
        function(control)
            if global_timer_id == 0 then
                update_classlist()
            end
        end)
    local copy_button_width = 40
    global_control_xref["classes"] = classes_list:GetControlID()
    local class_doc = dialog:CreateButton(x, y - win_mac(5,1))
    set_text(class_doc, "Documentation")
    global_control_xref[class_doc:GetControlID()] = classes_list:GetControlID()
    class_doc:SetWidth(col_width - copy_button_width - 5)
    dialog:RegisterHandleControlEvent(class_doc, function(control)
        if current_class_name == eligible_classes[current_class_name] then
            launch_docsite(current_class_name)
        else
            local class_info = global_class_index[current_class_name]
            if class_info then
                launch_docsite(class_info.namespace, class_info.filename)
            end
        end
    end)
    local class_copy = dialog:CreateButton(x + col_width - copy_button_width, y - win_mac(5, 1))
    set_text(class_copy, "Copy")
    global_control_xref[class_copy:GetControlID()] = classes_list:GetControlID()
    class_copy:SetWidth(copy_button_width)
    dialog:RegisterHandleControlEvent(class_copy, on_copy)
    local bottom_y = y
    x = x + col_width + sep_width
    global_progress_label = dialog:CreateStatic(x, bottom_y)
    global_progress_label:SetWidth(2.5*col_width)
    --macOS does not update label text in real time, but Windows does.
    --Therefore on macOS this is the only text that shows in the label
    set_text(global_progress_label, "initializing...")
    
    local properties_list = create_column(dialog, 170, col_width + col_extra, "Properties:", on_method_selection, context.filter_properties_text, handle_edit_control)
    global_control_xref["properties"] = properties_list:GetControlID()
    create_display_area (dialog, global_dialog_info[properties_list:GetControlID()], col_width + col_extra, true)
    x = x + col_width + col_extra + sep_width
    
    local methods_list = create_column(dialog, 170, col_width + col_extra, "Methods:", on_method_selection, context.filter_methods_text, handle_edit_control)
    global_control_xref["methods"] = methods_list:GetControlID()
    create_display_area (dialog, global_dialog_info[methods_list:GetControlID()], col_width + col_extra)
    x = x + col_width + col_extra + sep_width
    
    local class_methods_list = create_column(dialog, 170, col_width + col_extra, "Class Methods:", on_method_selection)
    global_control_xref["class_methods"] = class_methods_list:GetControlID()
    create_display_area (dialog, global_dialog_info[class_methods_list:GetControlID()], col_width + col_extra)
    x = x + col_width + col_extra
    
    -- create close button
    local close_button = dialog:CreateCloseButton(x-70, bottom_y)
    close_button:SetWidth(70)
    set_text(close_button, "Close")
    if dialog.RegisterCloseWindow then -- if this version of RGP Lua has RegisterHandleCloseButtonPressed
        dialog:RegisterCloseWindow(on_close)
    end
    if dialog.RegisterHandleKeyboardCommand then
        dialog:RegisterHandleKeyboardCommand(function(list_box, character)
            if utf8.char(character) == "C" then
                on_copy(list_box)
                return true
            end
            return false
        end)
    end
    if dialog.RegisterHandleListDoubleClick then
        dialog:RegisterHandleListDoubleClick(on_item_selected)
    end
    if dialog.RegisterHandleListEnterKey then
        dialog:RegisterHandleListEnterKey(function(control)
            -- use a timer to handle this, because Windows FX_Dialog can't open a dialog inside WM_KEYDOWN
            global_list_box = control
            global_dialog:SetTimer(global_popup_timer_id, 1)
            return true
        end)
    end
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
