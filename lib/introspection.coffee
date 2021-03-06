# Refactoring status: N/A
util = require 'util'
_ = require 'underscore-plus'

extractBetween = (str, s1, s2) ->
  str.substring(str.indexOf(s1)+1, str.lastIndexOf(s2))

getParent = (obj) ->
  obj.__super__?.constructor

getAncestors = (obj) ->
  ancestors = []
  ancestors.push (current=obj)
  while current = getParent(current)
    ancestors.push current
  ancestors

inspectFunction = (fn, name) ->
  # Calling super in the overridden constructor() function.
  #  Case-1: No override.
  #  CoffeeScript Source: N/A
  #  Compiled JavaScript: return C1.__super__.constructor.apply(this, arguments);
  #
  #  Case-2: super without parentheses.
  #  CoffeeScript Source: super
  #  Compiled JavaScript: C1.__super__.constructor.apply(this, arguments);
  #
  #  Case-3: super with explicit argument.
  #  CoffeeScript Source: super(a1)
  #  Compiled JavaScript: C1.__super__.constructor.call(this, a1);
  superBase = _.escapeRegExp("#{fn.name}.__super__.#{name}")
  superAsIs = superBase + _.escapeRegExp(".apply(this, arguments);") # Case-2
  defaultConstructor = '^return '+  superAsIs # Case-1
  superWithModify = superBase + '\\.call\\((.*)\\)' # Case-3

  fnString = fn.toString()
  fnBody = extractBetween(fnString, '{', '}').split("\n").map (e) -> e.trim()

  # Extract arguments from fnString. e.g. function(a1, a1){} -> ['a1', 'a2'].
  fnArgs = fnString.split("\n")[0].match(/\((.*)\)/)[1].split(/,\s*/g)

  # Replace ['arg1', 'arg2'] to ['@arg1', '@arg2'].
  # Only when instance variable assignment statement was found.
  fnArgs = fnArgs.map (arg) ->
    iVarAssign = '^' + _.escapeRegExp("this.#{arg} = #{arg};") + '$'
    if (_.detect(fnBody, (line) -> line.match(iVarAssign)))
      '@' + arg
    else
      arg
  argumentsSignature = '(' + fnArgs.join(', ') + ')'

  superSignature = null
  for line in fnBody
    if name is 'constructor' and line.match(defaultConstructor)
      superSignature = 'default'
    else if line.match(superAsIs)
      superSignature = 'super'
    else if m = line.match(superWithModify)
      args = m[1].replace(/this,?\s*/, '') # Delete 1st arg(=this) of apply() or call()
      args = args.replace(/this\./g, '@')
      superSignature = "super(#{args})"
    break if superSignature

  {argumentsSignature, superSignature}

excludeProperties = ['__super__']

inspectObject = (obj, options={}, prototype=false) ->
  excludeList = excludeProperties.concat (options.excludeProperties ? [])
  options.depth ?= 0
  prefix = '@'
  if prototype
    obj = obj.prototype
    prefix = '::'
  ancesstors = getAncestors(obj.constructor)
  ancesstors.shift() # drop myself.
  results = []
  for own prop, value of obj when prop not in excludeList
    s = "- #{prefix}#{prop}"
    if value instanceof options.recursiveInspect
      s += ":\n#{inspectInstance(value, options)}"
    else if _.isFunction(value)
      {argumentsSignature, superSignature} = inspectFunction(value, prop)
      if (prop is 'constructor') and (superSignature is 'default')
        continue # hide default constructor
      s += "`#{argumentsSignature}`"
      s += ": `#{superSignature}`" if superSignature?
    else
      s += ": ```#{util.inspect(value, options)}```"
    isOverridden = _.detect(ancesstors, (ancestor) -> ancestor::.hasOwnProperty(prop))
    s += ": **Overridden**" if isOverridden
    results.push s

  return null unless results.length
  results.join('\n')

report = (obj, options={}) ->
  name = obj.name
  {
    name: name
    ancesstorsNames: _.pluck(getAncestors(obj), 'name')
    command: getCommand(name)
    keymaps: getKeyBindingInfo(name)
    instance: inspectObject(obj, options)
    prototype: inspectObject(obj, options, true)
  }

reportModule = (mod, options) ->
  results = []
  for own prop, value of mod
    results.push report(value, options)
  results

sortByAncesstor = (list) ->
  mapped = list.map (obj, i) ->
    {index: i, value: obj.ancesstorsNames.slice().reverse()}

  compare = (v1, v2) ->
    a = v1.value[0]
    b = v2.value[0]
    if (a is undefined) and (b is undefined) then  0
    else if a is undefined then -1
    else if b is undefined then 1
    else if a < b then -1
    else if a > b then 1
    else
      a = index: v1.index, value: v1.value[1..]
      b = index: v2.index, value: v2.value[1..]
      compare(a, b)

  mapped.sort(compare).map((e) -> list[e.index])

# Return non-existent parent.
getVirtualParents = (list, options) ->
  names = _.pluck(list, 'ancesstorsNames')
  ancesstors = names.map((e) -> e.join(' < '))
  candidates = names.map((e) -> e[1..].join(' < ')).filter((e) -> e.length)

  virtuals = _.uniq(candidates.filter((e) -> e not in ancesstors))
  Base = require './base'
  virtuals.map (e) ->
    ancesstors = e.split(' < ')
    klass = ancesstors[0]
    obj = if klass is 'Base' then Base else Base.findClass(klass)
    r = report(obj, options)
    r.virtual = true
    r

genTableOfContent = (obj) ->
  {name, ancesstorsNames} = obj
  indentLevel = ancesstorsNames.length - 1
  indent = _.multiplyString('  ', indentLevel)
  link = ancesstorsNames[0..1].join('--').toLowerCase()
  s = "#{indent}- [#{name}](##{link})"
  s += ' *Not exported*' if obj.virtual?
  s

generateIntrospectionReport = (mods, options) ->
  pack = atom.packages.getActivePackage('vim-mode')
  {version} = pack.metadata
  results = _.flatten((reportModule(mod, options) for mod in mods))
  results = results.concat(getVirtualParents(results, options))
  results = sortByAncesstor(results)

  toc = results.map((e) -> genTableOfContent(e)).join('\n')
  body = []
  for result in results
    ancesstors = result.ancesstorsNames[0..1]
    header = "##{_.multiplyString('#', ancesstors.length)} #{ancesstors.join(" < ")}"
    s = []
    s.push header
    if result.virtual?
      s.push '*Not exported*'

    {command, keymaps, instance, prototype} = result
    s.push "- command: `#{command}`" if command?
    s.push formatKeymaps(keymaps) if keymaps?
    # s[s.length - 1] += "  \n" if s.length > 1
    s.push instance if instance?
    s.push prototype if prototype?
    body.push s.join("\n")

  date = new Date().toISOString()
  content = [
    '# TOM(TextObject, Operator, Motion) report.'
    "vim-mode version: #{version}  \n*generated at #{date}*"
    toc
    body.join("\n\n")
  ].join("\n\n")

  atom.workspace.open().then (editor) ->
    editor.setText content
    editor.setGrammar atom.grammars.grammarForScopeName('source.gfm')

formatKeymaps = (keymaps) ->
  s = []
  s.push '- keymaps'
  for keymap in keymaps
    {keystrokes, selector} = keymap
    keystrokes = keystrokes.replace(/(`|_)/g, '\\$1')
    s.push "  - #{selector}: <kbd>#{keystrokes}</kbd>"

  s.join("\n")

formatReport = (report) ->
  {instance, prototype, ancesstorsNames} = report
  s = []
  s.push "# #{ancesstorsNames.join(" < ")}"
  s.push instance if instance?
  s.push prototype if prototype?
  s.join("\n")

inspectInstance = (obj, options={}) ->
  indent = _.multiplyString(' ', options.indent ? 0)
  rep = report(obj.constructor, options)
  [
    "## #{obj}: #{rep.ancesstorsNames[0..1].join(" < ")}"
    inspectObject(obj, options)
    formatReport(rep)
  ].filter (e) -> e
  .join('\n').split('\n').map((e) -> indent + e).join('\n')

keymapsForVimMode = null
getKeyBindings =  ->
  return keymapsForVimMode if keymapsForVimMode
  pack = atom.packages.getActivePackage('vim-mode')
  keymapPath = pack.getKeymapPaths().pop()
  keymapsForVimMode =
    (k for k in atom.keymaps.getKeyBindings() when k.source is keymapPath)
  keymapsForVimMode

commandsForVimMode = null
getCommands = ->
  return commandsForVimMode if commandsForVimMode
  editor = atom.workspace.getActiveTextEditor()
  editorElement = atom.views.getView(editor)
  commands = atom.commands.findCommands(target: editorElement)
  commandsForVimMode = _.pluck(commands, 'name')
  commandsForVimMode

getCommand = (klass) ->
  command = "vim-mode:#{_.dasherize(klass)}"
  _.detect getCommands(), (c) ->
    c is command

getKeyBindingInfo = (klass) ->
  command = "vim-mode:#{_.dasherize(klass)}"
  results = null
  for k in getKeyBindings() when k.command is command
    {keystrokes, selector} = k
    keystrokes = keystrokes.replace(/shift-/, '')
    results ?= []
    results.push {keystrokes, selector}
  results

module.exports = {
  getKeyBindingInfo
  getAncestors
  getParent
  generateIntrospectionReport
  report
  inspectObject
  inspectInstance
}
