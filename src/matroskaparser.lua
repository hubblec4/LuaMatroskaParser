-- Lua Matroska Parser for parsing Matroska and WebM files
-- written by hubblec4

local ebml = require "ebml"
local mk = require "matroska"

-- constants
local DOCTYPE_MATROSKA = "matroska"
local DOCTYPE_WEBM = "webm"




-- -----------------------------------------------------------------------------
-- Matroska Parser -------------------------------------------------------------
-- -----------------------------------------------------------------------------

local Matroska_Parser = {
    -- path: file path
    path = "",

    -- file: a file stream, loaded with "io.open" for example
    file = nil,

    -- err_msg: contains an error string
    err_msg = "",

    -- is_valid: boolean read only, is the loaded file valid
    is_valid = false,

    -- is_webm: boolean read only, is the loaded file a WebM file
    is_webm = false,

    -- Matroska root element
    Segment = nil,

    -- Top-level elements for faster access
    SeekHead = nil,
    SeekHead2 = nil,
    Info = nil,
    Attachments = nil,
    Chapters = nil,
    Cues = nil,
    Tracks = nil,
    Tags = nil,

    -- useful element values
    seg_uuid = nil -- SegmentUUID as hex-string
}

-- Matroska Parser constructor
function Matroska_Parser:new(path, do_analyze)
    local elem = setmetatable({}, self)
    self.__index = self
    elem.path = path
    elem.file = nil

    -- Validate
    elem.is_valid, elem.err_msg = elem:_validate()

    -- Analyze, find all Top-Level elements
    -- do_analyze = false: means the user have to analyze manually
    if elem.is_valid and (do_analyze == nil or do_analyze == true) then
        elem.is_valid, elem.err_msg = elem:_analyze()
    end

    -- close file if invalid
    if not elem.is_valid then elem:close() end
    return elem
end

-- Get element from SeekHead
function Matroska_Parser:get_element_from_seekhead(elem_class)
    if self.SeekHead == nil then return nil end
    local seek = self.SeekHead:find_first_of(elem_class)
    -- no seek found in the first SeekHead
    if not seek then
        -- search in the second SeekHead if present
        if self.SeekHead2 ~= nil then
            seek = self.SeekHead2:find_first_of(elem_class)
        end
        if not seek then return nil end
    end

    self.file:seek("set", self.Segment:get_global_position(seek:location()))
    return ebml.find_next_element(self.file, {elem_class}, 0, 0 , false)
end

-- close: a method to clean some var's
function Matroska_Parser:close()
    if self.file ~= nil then
        self.file:close()
        self.file = nil
    end
end


-- Validate (private)
function Matroska_Parser:_validate()
    -- open file
    self.file = io.open(self.path, "rb")
    if not self.file then
        return false, "file couldn't be open"
    end

    -- check if an EBML and Segment element is present and a valid DocType is used
    
    -- find EBML element
    local elem = ebml.find_next_element(self.file, {ebml.EBML}, 0, 0, false)
    if not elem then
        return false, "EBML element not found."
    end

    -- EBML element found -> parse and check DocType
    elem:read_data(self.file)
    local doc = elem:get_child(ebml.DocType).value
    if doc ~= DOCTYPE_MATROSKA and doc ~= DOCTYPE_WEBM then
        return false, "'"..doc.."' is not a valid DocType value"
    end

    -- find Segment, note there can be Void elements before
    local read_size = 0xFFFFFF
    elem = ebml.find_next_element(self.file, {mk.Segment}, read_size, -1, false)
    while elem do
        if elem:get_context().id == mk.Segment:get_context().id then
            self.Segment = elem
            return true, ""
        end
        -- elem is a Void
        elem:skip_data(self.file)
        read_size = read_size - (elem.data_size + elem.data_size_len + 1)
        if read_size <= 0 then
            break
        end

        -- find next element
        elem = ebml.find_next_element(self.file, {mk.Segment}, read_size, -1, false)
    end

    return false, "Segment element not found."
end


-- Analyze (private)
function Matroska_Parser:_analyze()
    -- find all Top-Level elements, exclude Clusters
    local run_byte = self.Segment.data_position
    local end_byte = 0
    local elem
    local level = 0
    local semantic = mk.Segment:get_semantic()
    local id
    local found_cluster = false

    if self.Segment.unknown_data_size then
        end_byte = self.file:seek("end")
        self.file:seek("set", run_byte)
    else
        end_byte = self.Segment:end_position()
    end

    -- loop Segment content
    while run_byte < end_byte do
        elem, level = ebml.find_next_element(self.file, semantic, end_byte - run_byte, level)

        if not elem then
            return false, "Analyze error: no next element found"
        end

        id = elem:get_context().id

        -- first SeekHead
        if id == mk.seekhead.SeekHead:get_context().id  then
            elem:read_data(self.file) -- parse fully
            self.SeekHead = elem

        -- Info
        elseif id == mk.info.Info:get_context().id  then
            self.Info = elem
            self:parse_Info()

        -- Chapters
        elseif id == mk.chapters.Chapters:get_context().id  then
            elem:read_data(self.file) -- parse fully
            self.Chapters = elem

        -- Tracks
        elseif id == mk.tracks.Tracks:get_context().id  then
            elem:skip_data(self.file) -- skip data, parse later
            self.Tracks = elem

        -- Attachments
        elseif id == mk.attachs.Attachments:get_context().id  then
            elem:skip_data(self.file) -- skip data, parse later
            self.Attachments = elem

        -- Tags
        elseif id == mk.tags.Tags:get_context().id  then
            elem:read_data(self.file) -- parse fully
            self.Tags = elem

        -- first Cluster
        elseif id == mk.cluster.Cluster:get_context().id then
            found_cluster = true
            break

        -- hint: Cues are usually not before the first Cluster    

        else -- global elements or Dummy
            elem:skip_data(self.file) -- skip data
        end

        run_byte = elem:end_position()
    end

    -- no Cluster found, the end of the file has been reached
    if not found_cluster then return true, "" end

    -- search for a second SeekHead
    self.SeekHead2 = self:get_element_from_seekhead(mk.seekhead.SeekHead)
    if self.SeekHead2 then self.SeekHead2:read_data(self.file) end

    -- some elements are located after the Clusters
    -- and in some cases all Top-Level elements behind the Clusters
    -- use the SeekHeads to find the elements
    -- a SeekHead is maybe not alwyas present -> uses other technic TODO:

    if not self.Info then
        self.Info = self:get_element_from_seekhead(mk.info.Info)
        self:parse_Info()
    end

    if not self.Attachments then
        self.Attachments = self:get_element_from_seekhead(mk.attachs.Attachments)
    end
    
    if not self.Chapters then
        self.Chapters = self:get_element_from_seekhead(mk.chapters.Chapters)
        if self.Chapters then self.Chapters:read_data(self.file) end
    end

    if not self.Cues then
        self.Cues = self:get_element_from_seekhead(mk.cues.Cues)
    end

    if not self.Tracks then
        self.Tracks = self:get_element_from_seekhead(mk.tracks.Tracks)
    end

    if not self.Tags then
        self.Tags = self:get_element_from_seekhead(mk.tags.Tags)
        if self.Tags then self.Tags:read_data(self.file) end
    end
    
    return true, ""
end

-- bin2hex (private) - converts binary data to a hex-string
function Matroska_Parser:_bin2hex(bin)
    local hex = "0x"
    for i = 1, #bin do
        hex = hex .. string.format("%02X", string.byte(bin, i))
    end
    return hex
end

-- Parse Info (private)
function Matroska_Parser:parse_Info()
    if self.Info then
        self.Info:read_data(self.file) -- parse fully
        -- parse SegmentUUID
        self.seg_uuid = self.Info:find_child(mk.info.SegmentUUID)
        if self.seg_uuid then
            self.seg_uuid = self:_bin2hex(self.seg_uuid.value)
        end
    end
end

-- to_String: generates a human readable string for an element
local function get_elem_type(elem)
    return getmetatable(elem.__index)
end

function Matroska_Parser:to_string(elem, verbose)
    local result = ""

    local function do_verbose(_e)
        result = result .. " (data position: " .. _e.data_position
            .. ", data size: " .. _e.data_size .. ")"
    end

    local function get_string(_elem, level)
        local prefix = "|"
        for i = 1, level do
            prefix = prefix .. " "
        end
        prefix = prefix .. "+ "

        if _elem:is_master() then
            result = result .. prefix .. _elem:get_context().name
            if verbose then do_verbose(_elem) end

            for _, e in ipairs(elem.value) do
                result = result .. "\n" .. get_string(e, level + 1)
            end

        elseif _elem:is_dummy() then
            result = result .. prefix .. "Dummy: dummyID " .. _elem.dummy_id
            if verbose then do_verbose(_elem) end

        else -- all other types
            result = result .. prefix .. _elem:get_context().name .. ": "

            local e_type = getmetatable(_elem.__index) -- get the ebml type

            if e_type == ebml.utf8 or e_type == ebml.string or e_type == ebml.integer
            or e_type == ebml.uinteger or e_type == ebml.float then
                result = result .. _elem.value

            elseif e_type == ebml.date then
                result = result .. _elem:get_utc()

            else -- binary type
                -- print hex value for small binary like UUIDs
                if #_elem.value < 17 then
                    result = result .. self:_bin2hex(_elem.value)

                else -- more than 16 Bytes, TODO: Adler32
                    result = result .. "binary data" -- for the moment
                end
            end

            if verbose then do_verbose(_elem) end
        end

        return result
    end

    return get_string(elem, 0)
end


-- Matroska features -----------------------------------------------------------

-- Ordered chapters are used
function Matroska_Parser:ordered_chapters_are_used()
    if self.Chapters ~= nil then
        -- get the default edition and check if ordered chapters are used
        local def_edition = self.Chapters:get_default_edition()
        if def_edition
        and def_edition:get_child(mk.chapters.EditionFlagOrdered).value > 0 then
            if def_edition:find_child(mk.chapters.ChapterAtom) then
                return true
            end
        end
    end
    return false
end


-- Hard-Linking is used
function Matroska_Parser:hardlinking_is_used()
    -- check if the Hard-Linking is used
    -- retrun@1 : boolean - is used?
    -- return@2 SegmentUUID, return@3 PrevUUID, return@4 NextUUID

    -- WebM don't support Hard-Linking
    if self.is_webm then return false end

    -- check the UIDs
    local seg_id, prev_id, next_id = self:hardlinking_get_uids()

    -- no prev or next UID -> no Hard-Linking
    if prev_id == nil and next_id == nil then return false end

    -- Ordered Chapters or Soft-Linking overrides Hard-Linking
    -- check the Chapters
    if self:ordered_chapters_are_used() then return false end
    
    -- all is checked and Hard-Linking is used
    return true, seg_id, prev_id, next_id
end

-- Hard-Linking get UIDs
function Matroska_Parser:hardlinking_get_uids()
    -- check the UIDs
    if self.Info == nil then return end

    local prev_id = self.Info:find_child(mk.info.PrevUUID)
    if prev_id then prev_id = self:_bin2hex(prev_id.value) end
    
    local next_id = self.Info:find_child(mk.info.NextUUID)
    if next_id then next_id = self:_bin2hex(next_id.value) end

    return self.seg_uuid, prev_id, next_id
end



-- Export module ---------------------------------------------------------------
local module = {
    Matroska_Parser = Matroska_Parser
}
return module