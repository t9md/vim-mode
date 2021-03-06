# Refactoring status: 100%
Delegato = require 'delegato'
_ = require 'underscore-plus'
{Emitter, CompositeDisposable} = require 'atom'
{Hover} = require './hover'
{Input} = require './input'
settings = require './settings'

Operator        = require './operator'
Motion          = require './motion'
TextObject      = require './text-object'
InsertMode      = require './insert-mode'
Scroll          = require './scroll'
VisualBlockwise = require './visual-blockwise'

OperationStack  = require './operation-stack'
CountManager    = require './count-manager'
MarkManager     = require './mark-manager'
ModeManager     = require './mode-manager'
RegisterManager = require './register-manager'

Developer = null # delay

module.exports =
class VimState
  Delegato.includeInto(this)

  editor: null
  operationStack: null
  destroyed: false
  replaceModeListener: null
  developer: null
  lastOperation: null

  # Mode handling is delegated to modeManager
  delegatingMethods = [
    'isMode'
    'activateNormalMode'
    'activateInsertMode'
    'activateOperatorPendingMode'
    'activateReplaceMode'
    'replaceModeUndo'
    'deactivateInsertMode'
    'deactivateVisualMode'
    'activateVisualMode'
    'resetNormalMode'
    'setInsertionCheckpoint'
  ]
  delegatingProperties = [
    'mode'
    'submode'
  ]
  @delegatesProperty delegatingProperties..., toProperty: 'modeManager'
  @delegatesMethods delegatingMethods..., toProperty: 'modeManager'

  constructor: (@editorElement, @statusBarManager, @globalVimState) ->
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @editor = @editorElement.getModel()
    @history = []
    @subscriptions.add @editor.onDidDestroy =>
      @destroy()

    @count = new CountManager(this)
    @mark = new MarkManager(this)
    @register = new RegisterManager(this)
    @operationStack = new OperationStack(this)
    @modeManager = new ModeManager(this)
    @hover = new Hover(this)
    @input = new Input(this)

    @editorElement.addEventListener 'mouseup', @checkSelections.bind(this)

    if atom.commands.onDidDispatch?
      @subscriptions.add atom.commands.onDidDispatch ({target}) =>
        if target is @editorElement
          @checkSelections()
        return unless settings.get('showCursorInVisualMode')
        switch
          when @isMode('visual', 'characterwise')
            @showCursors(@editor.getCursors())
          when @isMode('visual', 'blockwise')
            cursors =
              for s in @editor.getSelections() when s.marker.getProperties().vimModeBlockwiseHead
                s.cursor
            @showCursors(cursors)

    @editorElement.classList.add("vim-mode")
    @init()
    if settings.get('startInInsertMode')
      @activateInsertMode()
    else
      @activateNormalMode()

  # setCursorStyle ({width, left})

  destroy: ->
    return if @destroyed
    @destroyed = true
    @subscriptions.dispose()
    if @editor.isAlive()
      @deactivateInsertMode()
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove("vim-mode")
      @editorElement.classList.remove("normal-mode")
    # @editorElement.removeEventListener 'mouseup', @checkSelections
    @editor = null
    @editorElement = null
    @lastOperation = null
    @hover.destroy()
    @input.destroy()
    @emitter.emit 'did-destroy'

  onDidFailToCompose: (fn) ->
    @emitter.on('failed-to-compose', fn)

  onDidDestroy: (fn) ->
    @emitter.on('did-destroy', fn)

  registerCommands: (commands) ->
    for name, fn of commands
      do (fn) =>
        @subscriptions.add atom.commands.add(@editorElement, "vim-mode:#{name}", fn)

  # Register operation command.
  # command-name is automatically mapped to correspoinding class.
  # e.g.
  #   join -> Join
  #   scroll-down -> ScrollDown
  registerOperationCommands: (kind, names) ->
    commands = {}
    for name in names
      do (name) =>
        if match = /^(a|inner)-(.*)/.exec(name)?.slice(1, 3) ? null
          # Mapping command name to TextObject
          inclusive = match[0] is 'a'
          klass = _.capitalize(_.camelize(match[1]))
        else
          klass = _.capitalize(_.camelize(name))
        commands[name] = =>
          try
            op = new kind[klass](this)
            op.inclusive = inclusive if inclusive
            @operationStack.push op
          catch error
            @lastOperation = null
            throw error unless error.isOperationAbortedError?()

    @registerCommands(commands)

  # Initialize all of vim-mode' commands.
  init: ->
    @registerCommands
      'activate-normal-mode': => @activateNormalMode()
      'activate-linewise-visual-mode': => @activateVisualMode('linewise')
      'activate-characterwise-visual-mode': => @activateVisualMode('characterwise')
      'activate-blockwise-visual-mode': => @activateVisualMode('blockwise')
      'reset-normal-mode': => @resetNormalMode()
      'set-count': (e) => @count.set(e) # 0-9
      'set-register-name': => @register.setName() # "
      'reverse-selections': => @reverseSelections() # o
      'undo': => @undo() # u
      'replace-mode-backspace': => @replaceModeUndo()

    @registerOperationCommands InsertMode, [
      'insert-register'
      'copy-from-line-above', 'copy-from-line-below'
    ]

    @registerOperationCommands TextObject, [
      'inner-word'           , 'a-word'
      'inner-whole-word'     , 'a-whole-word'
      'inner-double-quote'  , 'a-double-quote'
      'inner-single-quote'  , 'a-single-quote'
      'inner-back-tick'     , 'a-back-tick'
      'inner-paragraph'      , 'a-paragraph'
      'inner-any-pair'       , 'a-any-pair'
      'inner-curly-bracket' , 'a-curly-bracket'
      'inner-angle-bracket' , 'a-angle-bracket'
      'inner-square-bracket', 'a-square-bracket'
      'inner-parenthesis'    , 'a-parenthesis'
      'inner-tag'           , # 'a-tag'
      'inner-comment'        , 'a-comment'
      'inner-indentation'    , 'a-indentation'
      'inner-fold'           , 'a-fold'
      'inner-function'       , 'a-function'
      'inner-current-line'   , 'a-current-line'
      'inner-entire'         , 'a-entire'
    ]

    @registerOperationCommands Motion, [
      'move-to-beginning-of-line',
      'repeat-find', 'repeat-find-reverse',
      'move-down', 'move-up', 'move-left', 'move-right',
      'move-to-next-word'     , 'move-to-next-whole-word',
      'move-to-end-of-word'   , 'move-to-end-of-whole-word',
      'move-to-previous-word' , 'move-to-previous-whole-word',
      'move-to-next-paragraph', 'move-to-previous-paragraph',
      'move-to-first-character-of-line', 'move-to-last-character-of-line',
      'move-to-first-character-of-line-up', 'move-to-first-character-of-line-down',
      'move-to-first-character-of-line-and-down',
      'move-to-last-nonblank-character-of-line-and-down',
      'move-to-first-line', 'move-to-last-line',
      'move-to-top-of-screen', 'move-to-bottom-of-screen', 'move-to-middle-of-screen',
      'scroll-half-screen-up', 'scroll-half-screen-down',
      'scroll-full-screen-up', 'scroll-full-screen-down',
      'repeat-search'          , 'repeat-search-backwards',
      'move-to-mark'           , 'move-to-mark-line',
      'find'                   , 'find-backwards',
      'till'                   , 'till-backwards',
      'search'                 , 'reverse-search',
      'search-current-word'    , 'reverse-search-current-word',
      'bracket-matching-motion',
    ]

    @registerOperationCommands Operator, [
      'activate-insert-mode', 'insert-after',
      'activate-replace-mode',
      'substitute', 'substitute-line',
      'insert-at-beginning-of-line', 'insert-after-end-of-line',
      'insert-below-with-newline', 'insert-above-with-newline',
      'delete', 'delete-to-last-character-of-line',
      'delete-right', 'delete-left',
      'change', 'change-to-last-character-of-line',
      'yank', 'yank-line',
      'put-after', 'put-before',
      'upper-case', 'lower-case', 'toggle-case', 'toggle-case-and-move-right',
      'camel-case', 'snake-case', 'dash-case',
      'surround', 'surround-word',
      'delete-surround', 'delete-surround-any-pair'
      'change-surround', 'change-surround-any-pair'
      'join',
      'indent', 'outdent', 'auto-indent',
      'increase', 'decrease',
      'repeat', 'mark', 'replace',
      'replace-with-register'
      'toggle-line-comments'
      'operate-on-inner-word'
    ]

    @registerOperationCommands Scroll, [
      'scroll-down'            , 'scroll-up'                    ,
      'scroll-cursor-to-top'   , 'scroll-cursor-to-top-leave'   ,
      'scroll-cursor-to-middle', 'scroll-cursor-to-middle-leave',
      'scroll-cursor-to-bottom', 'scroll-cursor-to-bottom-leave',
      'scroll-cursor-to-left'  , 'scroll-cursor-to-right'       ,
    ]

    @registerOperationCommands VisualBlockwise, [
      'blockwise-other-end',
      'blockwise-move-down',
      'blockwise-move-up',
      'blockwise-delete-to-last-character-of-line',
      'blockwise-change-to-last-character-of-line',
      'blockwise-insert-at-beginning-of-line',
      'blockwise-insert-after-end-of-line',
      'blockwise-escape',
    ]

    # Load developer helper commands.
    if atom.inDevMode()
      Developer ?= require './developer'
      @developer = new Developer(this)
      @developer.init()

  reset: ->
    @count.reset()
    @register.reset()
    @hover.reset()

  # Miscellaneous commands
  # -------------------------
  undo: ->
    @editor.undo()
    @activateNormalMode()

  reverseSelections: ->
    reversed = not @editor.getLastSelection().isReversed()
    @syncSelectionsReversedSate(reversed)

  syncSelectionsReversedSate: (reversed) ->
    for selection in @editor.getSelections()
      selection.setBufferRange(selection.getBufferRange(), {reversed})

  # Search History
  # -------------------------
  pushSearchHistory: (search) -> # should be saveSearchHistory for consistency.
    @globalVimState.searchHistory.unshift search

  getSearchHistoryItem: (index = 0) ->
    @globalVimState.searchHistory[index]

  checkSelections: ->
    return unless @editor?
    if @editor.getSelections().every((s) -> s.isEmpty())
      if @isMode('normal')
        @dontPutCursorsAtEndOfLine()
      else if @isMode('visual')
        @activateNormalMode()
    else
      if @isMode('normal')
        @activateVisualMode('characterwise')
      else
        # When cursor is added selection is empty
        # using editor.onDidAddCursor not work since at the timing event callbacked,
        # cursor.selection is `undefined` and editor.getCursors().length isnt editor.getSelections().length
        lastSelection = @editor.getLastSelection()
        if lastSelection.isEmpty()
          lastSelection.selectRight()

  showCursors: (cursors) ->
    for cursor in cursors
      cursor.setVisible(true) unless cursor.isVisible()
      if cursor.selection.isReversed()
        @editorElement.classList.add('reversed')
      else
        @editorElement.classList.remove('reversed')

  dontPutCursorsAtEndOfLine: ->
    # if @editor.getPath()?.endsWith 'tryit.coffee'
    #   return
    for cursor in @editor.getCursors() when cursor.isAtEndOfLine()
      continue if cursor.isAtBeginningOfLine()
      {goalColumn} = cursor
      cursor.moveLeft()
      cursor.goalColumn = goalColumn
