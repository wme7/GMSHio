function [V,VE,SE,LE,PE,mapPhysNames,info] = GMSHparserV2(filename)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%     Extract entities contained in a single GMSH file in format v2.2 
%
%      Coded by Manuel A. Diaz @ Pprime | Univ-Poitiers, 2022.01.21
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% Example call: GMSHparserV2('filename.msh')
%
% Output:
%     V: the vertices (nodes coordinates) -- (Nx3) array
%    VE: volumetric elements (tetrahedrons) -- structure
%    SE: surface elements (triangles,quads) -- structure
%    LE: curvilinear elements (lines/edges) -- structure
%    PE: point elements (singular vertices) -- structure
%    mapPhysNames: maps phys.tag --> phys.name  -- map structure
%    info: version, format, endian test -- structure
%
% Note: This parser is designed to capture the following elements:
%
% Point:                Line:                   Triangle:
%
%        v                                              v
%        ^                                              ^
%        |                       v                      |
%        +----> u                ^                      2
%       0                        |                      |`\
%                                |                      |  `\
%                          0-----+-----1 --> u          |    `\
%                                                       |      `\
% Tetrahedron:                                          |        `\
%                                                       0----------1 --> u
%                    v
%                   ,
%                  /
%               2
%             ,/|`\                    Based on the GMSH guide 4.9.4
%           ,/  |  `\                  This are lower-order elements 
%         ,/    '.   `\                identified as:
%       ,/       |     `\                  E-1 : 2-node Line 
%     ,/         |       `\                E-2 : 3-node Triangle
%    0-----------'.--------1 --> u         E-4 : 4-node tetrahedron
%     `\.         |      ,/                E-15: 1-node point
%        `\.      |    ,/
%           `\.   '. ,/                Other elements can be added to 
%              `\. |/                  this parser by modifying the 
%                 `3                   Read Elements stage.
%                    `\.
%                       ` w            Happy coding ! M.D. 02/2022.
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Read all sections

file = fileread(filename);
% Extract strings between:
MeshFormat    = extractBetween(file,['$MeshFormat',newline],[newline,'$EndMeshFormat']);
PhysicalNames = extractBetween(file,['$PhysicalNames',newline],[newline,'$EndPhysicalNames']);
Nodes         = extractBetween(file,['$Nodes',newline],[newline,'$EndNodes']);
Elements      = extractBetween(file,['$Elements',newline],[newline,'$EndElements']);

% Sanity check
if isempty(MeshFormat),    error('Error - Wrong File Format!'); end
if isempty(PhysicalNames), error('Error - No Physical names!'); end
if isempty(Nodes),         error('Error - Nodes are missing!'); end
if isempty(Elements),      error('Error - No elements found!'); end

% Split data lines into cells (Only in Matlab!)
cells_MF   = splitlines(MeshFormat);
cells_PN   = splitlines(PhysicalNames);
cells_N    = splitlines(Nodes);
cells_E    = splitlines(Elements);

%% Define map of costum Boundary types (BC_type)
% BCnames = { 'BCfile','free','wall','outflow',...
%         'imposedPressure','imposedVelocities',...
%         'axisymmetric_y','axisymmetric_x',...
%         'BC_rec','free_rec','wall_rec','outflow_rec',...
%         'imposedPressure_rec','imposedVelocities_rec',...
%         'axisymmetric_y_rec','axisymmetric_x_rec',...
%         'piston_pressure','piston_velocity',...
%         'recordingObject','recObj','piston_stress'};
% BCsolverIds = [0:7,10:20,20,21]; % costume IDs expected in our solver
% BC_type = containers.Map(BCnames,BCsolverIds);

%% Identify critical data within each section:

%********************%
% 1. Read Mesh Format
%********************%
line_data = sscanf(cells_MF{1},'%f %d %d');
info.version   = line_data(1);	% 2.2 is expected
info.file_type = line_data(2);	% 0:ASCII or 1:Binary
info.mode      = line_data(3);	% 1 in binary mode to detect endianness 

% Sanity check
if (info.version ~= 2.2), error('Error - Expected mesh format v2.2'); end
if (info.file_type ~= 0), error('Error - Binary file not allowed'); end

%***********************%
% 2. Read Physical Names
%***********************%
phys = struct('dim',{},'tag',{},'name',{});
numPhysicalNames = sscanf(cells_PN{1},'%d');
for n = 1:numPhysicalNames
   parts = strsplit(cells_PN{n+1});
   phys(n).dim  = str2double(parts{1});
   phys(n).tag  = str2double(parts{2});
   phys(n).name = strrep(parts{3},'"','');
end
mapPhysNames = containers.Map([phys.tag],{phys.name});
info.Dim = max([phys.dim]);

%***********************%
% 3. Read Nodes
%***********************%
l=1; % read first line
numNodes = sscanf(cells_N{l},'%d');

% allocate space for nodal data
V = zeros(numNodes,3); % [x,y,z] 

% Nodes Coordinates
for i=1:numNodes
    l = l+1; % update line counter
    line_data = sscanf(cells_N{l},'%d %g %g %g'); % [i,x(i),y(i),z(i)]
    V(i,:) = line_data(2:4);
end
fprintf('Total vertices found = %g\n',length(V));

%***********************%
% 4. Read Elements
%***********************%
l=1; % read first line
numElements = sscanf(cells_E{l},'%d');

% Line Format:
% elm-number elm-type number-of-tags < tag > ... node-number-list
PE.EToV=[]; PE.phys_tag=[]; PE.geom_tag=[]; PE.part_tag=[]; PE.Etype=[];
LE.EToV=[]; LE.phys_tag=[]; LE.geom_tag=[]; LE.part_tag=[]; LE.Etype=[];
SE.EToV=[]; SE.phys_tag=[]; SE.geom_tag=[]; SE.part_tag=[]; SE.Etype=[];
VE.EToV=[]; VE.phys_tag=[]; VE.geom_tag=[]; VE.part_tag=[]; VE.Etype=[];

e0 = 0; % point Element counter
e1 = 0; % Lines Element counter
e2 = 0; % Triangle Element counter
e3 = 0; % Tetrehedron Element counter
for i = 1:numElements
    n = sscanf(cells_E{1+i}, '%d')';
    %elementID = n(1); % we use a local numbering instead
    elementType = n(2);
    numberOfTags = n(3);
    switch elementType
        case 1 % Line elements
            e1 = e1 + 1; % update element counter
            LE.Etype(e1,1) = elementType;
            LE.EToV(e1,:) = n(3+numberOfTags+1:end);
            if numberOfTags > 0 % get tags if they exist
                tags = n(3+(1:numberOfTags)); % get tags
                % tags(1) : physical entity to which the element belongs
                % tags(2) : elementary number to which the element belongs
                % tags(3) : number of partitions to which the element belongs
                % tags(4) : partition id number
                if length(tags) >= 1
                    LE.phys_tag(e1,1) = tags(1);
                    if length(tags) >= 2
                        LE.geom_tag(e1,1) = tags(2);
                        if length(tags) >= 4
                            LE.part_tag(e1,1) = tags(4);
                        end
                    end
                end
            end
        case 2 % triangle elements
            e2 = e2 + 1; % update element counter
            SE.Etype(e2,1) = elementType;
            SE.EToV(e2,:) = n(3+numberOfTags+1:end);
            if numberOfTags > 0 % get tags if they exist
                tags = n(3+(1:numberOfTags)); % get tags
                % tags(1) : physical entity to which the element belongs
                % tags(2) : elementary number to which the element belongs
                % tags(3) : number of partitions to which the element belongs
                % tags(4) : partition id number
                if length(tags) >= 1
                    SE.phys_tag(e2,1) = tags(1);
                    if length(tags) >= 2
                        SE.geom_tag(e2,1) = tags(2);
                        if length(tags) >= 4
                            SE.part_tag(e2,1) = tags(4);
                        end
                    end
                end
            end
        case 4 % tetrahedron elements
            e3 = e3 + 1; % update element counter
            VE.Etype(e3,1) = elementType;
            VE.EToV(e3,:) = n(3+numberOfTags+1:end);
            if numberOfTags > 0 % get tags if they exist
                tags = n(3+(1:numberOfTags)); % get tags
                % tags(1) : physical entity to which the element belongs
                % tags(2) : elementary number to which the element belongs
                % tags(3) : number of partitions to which the element belongs
                % tags(4) : partition id number
                if length(tags) >= 1
                    VE.phys_tag(e3,1) = tags(1);
                    if length(tags) >= 2
                        VE.geom_tag(e3,1) = tags(2);
                        if length(tags) >= 4
                            VE.part_tag(e3,1) = tags(4);
                        end
                    end
                end
            end
        case 15 % point element
            e0 = e0 + 1; % update element counter
            PE.Etype(e0,1) = elementType;
            PE.EToV(e0,:) = n(3+numberOfTags+1:end);
            if numberOfTags > 0 % if they exist
                tags = n(3+(1:numberOfTags)); % get tags
                % tags(1) : physical entity to which the element belongs
                % tags(2) : elementary number to which the element belongs
                % tags(3) : number of partitions to which the element belongs
                % tags(4) : partition id number
                if length(tags) >= 1
                    PE.phys_tag(e0,1) = tags(1);
                    if length(tags) >= 2
                        PE.geom_tag(e0,1) = tags(2);
                        if length(tags) >= 4
                            PE.part_tag(e0,1) = tags(4);
                        end
                    end
                end
            end
        otherwise, error('element not set yet!');
    end
end
%
% Find the total number of partitions
info.numPartitions = max(SE.part_tag);
%
fprintf('Total point-elements found = %g\n',e0);
fprintf('Total line-elements found = %g\n',e1);
fprintf('Total surface-elements found = %g\n',e2);
fprintf('Total volume-elements found = %g\n',e3);
% Sanity check
if numElements ~= (e0+e1+e2+e3)
    error('Total number of elements missmatch!'); 
end
%
end % GMSHv2 read function