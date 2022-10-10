{
  local defaultUIDFieldPath = 'metadata.annotations["crossplane.io/external-name"]',

  local defaultIgnores = [
    'status.conditions',
    'spec.writeConnectionSecretToRef'
  ],

  NameToPlural(config):: (

    if std.objectHas(config, "plural") then
      std.asciiLower(config.plural)
    else
      local lname = std.asciiLower(config.name);
      local length = std.length(lname);
      local last = std.substr(lname, length - 1, 1);
      local replace = if last == 'y' then 'ie' else last;
      std.substr(lname,0,length -1) + replace + 's'
  ),
  FQDN(name, group):: (
    '%s.%s' % [std.asciiLower(name), group]
  ),
  GenerateCategories(group):: (
    ['crossplane', 'composition', std.split(group, '.')[0]]
  ),
  GenerateLabels(provider):: (
    {
      'example.cloud/provider': provider,
    }
  ),
  local labelize(fqdn) = (
    "metadata.labels['%s']" % [fqdn]
  ),
  Labelize(fqdn):: (
    labelize(fqdn)
  ),
  GenCompanyControllingLabel(fields):: (
    [labelize('controlling.example.cloud/' + field) for field in fields]
  ),
  GenCompanyGenericLabel(fields):: (
    [labelize('tags.example.cloud/' + field) for field in fields]
  ),
  GenExternalGenericLabel(fields):: (
    [labelize(field) for field in fields]
  ),
  GenGlobalLabel(fields):: (
    [labelize('crossplane.io/' + field) for field in fields]
  ),
  local genPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy) = (
    {
      [srcFieldName]: fieldFrom,
      [dstFieldName]: fieldTo,
      policy: {
        fromFieldPath: policy,
      },
      type: type,
    }
  ),
  GenPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy):: (
    [genPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy)]
  ),
  local genSecretPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy) = (
    {
      [srcFieldName]: fieldFrom,
      [dstFieldName]: fieldTo,
      policy: {
        fromFieldPath: policy,
      },
      type: type,
      transforms: [
        {
          type: "string",
          string: {
            fmt: '%s-secret'
          },
        },
      ],
    }
  ),
  GenSecretPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy):: (
    [genSecretPatch(type, fieldFrom, fieldTo, srcFieldName, dstFieldName, policy)]
  ),
  GenOptionalPatchFrom(fields):: (
    [
      genPatch('FromCompositeFieldPath', field, field, 'fromFieldPath', 'toFieldPath', 'Optional')
      for field in fields
    ]
  ),
  GenOptionalPatchTo(fields):: (
    [
      genPatch('ToCompositeFieldPath', field, field, 'toFieldPath', 'fromFieldPath', 'Optional')
      for field in fields
    ]
  ),
  GetDefaultComposition(compositions):: (
    local default = [c.name for c in compositions if 'default' in c && c.default];
    assert std.length(default) == 1 : 'Could not find a default composition. One composition must have default: true!';
    default[0]
  ),
  GetVersion(crd, version):: (
    local fv = [v for v in crd.spec.versions if 'name' in v && v.name == version];
    assert std.length(fv) == 1 : 'Could not find CRD with version %s' % version;
    fv[0]
  ),
  local overrides(config) = {
    [o.path]: o.override
    for o in config.overrideFields
    if 'override' in o
  },
  local ignores(config) = [
    o.path
    for o in config.overrideFields
    if 'ignore' in o && o.ignore
  ] + defaultIgnores,
  local values(config) = {
    [o.path]: o.value
    for o in config.overrideFields
    if 'value' in o
  },
  local joinPath(path, item) = (
    std.join('.', path + [item])
  ),
  local splitPath(path) = (
    std.split(path, '.')
  ),
  local updatePath(path, name) = (
    if name != 'properties' then
      path + [name]
    else
      path
  ),
  local recurseWithPath(init, obj, path, foldFunc, filterFunc, valueFunc) = (
    if std.isObject(obj) then
      std.foldl(foldFunc, std.filterMap(
        function(n) (
          filterFunc(obj, path, n)
        ),
        function(n) (
          valueFunc(obj, path, n, recurseWithPath)
        ),
        std.objectFields(obj)
      ), init)
    else
      valueFunc(obj, path, path[std.length(path) - 1], recurseWithPath)
  ),
  GenerateSchema(obj, config, path):: (
    local ignorePaths = ignores(config);
    local overridePaths = overrides(config);

    local foldFunc = function(r, n) r + n;

    local filterFunc = function(object, fullPath, name) (
      !std.member(ignorePaths, joinPath(fullPath, name))
    );

    local valueFunc = function(object, fullPath, name, recurse) (
      if !std.isObject(object) then
        object
      else
        local jp = joinPath(fullPath, name);
        if jp in overridePaths then
          { [name]+: object[name] + overridePaths[jp] }
        else
          { [name]+: recurse(
            {},
            object[name],
            updatePath(fullPath, name),
            foldFunc,
            filterFunc,
            valueFunc
          ) }
    );
    recurseWithPath({}, obj, path, foldFunc, filterFunc, valueFunc)
  ),
  GeneratePatchPaths(obj, config, path):: (
    local filterFunc = function(object, fullPath, name) (
      std.isObject(object[name])
    );
    local foldFunc = function(r, n) (
      if std.isArray(n) then
        r + std.prune(n)
      else
        r + [n]
    );
    local valueFunc = function(object, fullPath, name, recurse) (
      local o = object[name];
      if 'type' in o && o.type == 'object' && !('additionalProperties' in object[name]) || name == 'properties' then
        recurse([], object[name], updatePath(fullPath, name), foldFunc, filterFunc, valueFunc)
      else
        joinPath(fullPath, name)
    );
    recurseWithPath([], obj, path, foldFunc, filterFunc, valueFunc)
  ),
  SetDefaults(config):: (
    local defaultValues = values(config);
    std.foldl(function(a, b) a + b, std.map(function(key) (
      local sp = splitPath(key);
      local sl = std.length(sp) - 1;
      std.foldr(function(r, n) (
        { [r]+: n }
      ), sp[0:sl], { [sp[sl]]: defaultValues[key] })
    ), std.objectFields(defaultValues)), {})
  ),
  FilterPrinterColumns(columns):: (
    std.filter(function(c) !std.startsWith(c.jsonPath, '.status.conditions'), columns)
  ),
  GetUIDFieldPath(config):: (
    if 'uidFieldPath' in config then
      config.uidFieldPath
    else
      defaultUIDFieldPath
  ),
}