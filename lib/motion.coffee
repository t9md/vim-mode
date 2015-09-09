# Refactoring status: 20%
# [TODO]
# #774
# #783

# Motion is either @inclusive or @exclusive
# Operator is either @linewise, @characterwise or @blockwise

{Point} = require 'atom'
_ = require 'underscore-plus'

settings = require './settings'
{SearchViewModel} = require './view'
Base = require './base'

WholeWordRegex = /\S+/
WholeWordOrEmptyLineRegex = /^\s*$|\S+/
AllWhitespace = /^\s$/

class Motion extends Base
  @extend()
  complete: true
  recordable: false
  inclusive: false
  linewise: false
  defaultCount: 1

  select: (options) ->
    for selection in @editor.getSelections()
      # FIXME: Order is important maybe
      switch
        when @isLinewise() then @selectLinewise(selection, options)
        when @vimState.isVisualMode() then @selectVisual(selection, options)
        when @inclusive then @selectInclusive(selection, options)
        else
          @moveSelection(selection, options)

    @editor.mergeCursors()
    @editor.mergeIntersectingSelections()
    (not s.isEmpty() for s in @editor.getSelections())

  execute: ->
    @editor.moveCursors (cursor) =>
      @moveCursor(cursor)

  selectLinewise: (selection, options) ->
    selection.modifySelection =>
      [oldStartRow, oldEndRow] = selection.getBufferRowRange()

      wasEmpty = selection.isEmpty()
      wasReversed = selection.isReversed()
      unless wasEmpty or wasReversed
        selection.cursor.moveLeft()

      @moveCursor(selection.cursor, options)

      isEmpty = selection.isEmpty()
      isReversed = selection.isReversed()
      unless isEmpty or isReversed
        selection.cursor.moveRight()

      [newStartRow, newEndRow] = selection.getBufferRowRange()

      if isReversed and not wasReversed
        newEndRow = Math.max(newEndRow, oldStartRow)
      if wasReversed and not isReversed
        newStartRow = Math.min(newStartRow, oldEndRow)

      selection.setBufferRange([[newStartRow, 0], [newEndRow + 1, 0]])

  selectInclusive: (selection, options) ->
    return @selectVisual(selection, options) unless selection.isEmpty()

    selection.modifySelection =>
      @moveCursor(selection.cursor, options)
      return if selection.isEmpty()

      if selection.isReversed()
        # for backward motion, add the original starting character of the motion
        {start, end} = selection.getBufferRange()
        selection.setBufferRange([start, [end.row, end.column + 1]])
      else
        # for forward motion, add the ending character of the motion
        selection.cursor.moveRight()

  selectVisual: (selection, options) ->
    selection.modifySelection =>
      range = selection.getBufferRange()
      [oldStart, oldEnd] = [range.start, range.end]

      # in visual mode, atom cursor is after the last selected character,
      # so here put cursor in the expected place for the following motion
      wasEmpty = selection.isEmpty()
      wasReversed = selection.isReversed()
      unless wasEmpty or wasReversed
        selection.cursor.moveLeft()

      # put cursor back after the last character so it is also selected
      @moveCursor(selection.cursor, options)

      isEmpty = selection.isEmpty()
      isReversed = selection.isReversed()
      unless isEmpty or isReversed
        selection.cursor.moveRight()

      range = selection.getBufferRange()
      [newStart, newEnd] = [range.start, range.end]

      # if we reversed or emptied a normal selection
      # we need to select again the last character deselected above the motion
      if (isReversed or isEmpty) and not (wasReversed or wasEmpty)
        selection.setBufferRange([newStart, [newEnd.row, oldStart.column + 1]])

      # if we re-reversed a reversed non-empty selection,
      # we need to keep the last character of the old selection selected
      if wasReversed and not wasEmpty and not isReversed
        selection.setBufferRange([[oldEnd.row, oldEnd.column - 1], newEnd])

      # keep a single-character selection non-reversed
      range = selection.getBufferRange()
      [newStart, newEnd] = [range.start, range.end]
      if selection.isReversed() and newStart.row is newEnd.row and newStart.column + 1 is newEnd.column
        selection.setBufferRange(range, reversed: false)

  moveSelection: (selection, options) ->
    selection.modifySelection =>
      @moveCursor(selection.cursor, options)

  isLinewise: ->
    if @vimState.isVisualMode()
      @vimState.submode is 'linewise'
    else
      @linewise

  countTimes: (fn) ->
    _.times @getCount(@defaultCount), ->
      fn()

  isAt: (cursor, where) ->
    switch where
      when 'BoL' then cursor.isAtBeginningOfLine()
      when 'EoL' then cursor.isAtEndOfLine()
      when 'EoF' then cursor.getEofBufferPosition().isEqual(@editor.getEofBufferPosition())
      when 'BoF' then cursor.getEofBufferPosition().isEqual(Point.ZERO)

  getLastScreenRow: ->
    @editor.getLastScreenRow()

  getLastBufferRow: ->
    @editor.getLastBufferRow()

  lineTextForBufferRow: (bufferRow) ->
    @editor.lineTextForBufferRow(bufferRow)

  bufferRangeForBufferRow: (bufferRow) ->
    @editor.bufferRangeForBufferRow(bufferRow)

  getEofBufferPosition: ->
    @editor.getEofBufferPosition()

class CurrentSelection extends Motion
  @extend()
  constructor: ->
    super
    @lastSelectionRange = @editor.getSelectedBufferRange()
    @wasLinewise = @isLinewise()

  execute: ->
    @countTimes -> true

  select: (count=1) ->
    # in visual mode, the current selections are already there
    # if we're not in visual mode, we are repeating some operation and need to re-do the selections
    unless @vimState.isVisualMode()
      if @wasLinewise
        @selectLines()
      else
        @selectCharacters()
    @countTimes -> true

  selectLines: ->
    lastSelectionExtent = @lastSelectionRange.getExtent()
    for selection in @editor.getSelections()
      cursor = selection.cursor.getBufferPosition()
      selection.setBufferRange [[cursor.row, 0], [cursor.row + lastSelectionExtent.row, 0]]
    return

  selectCharacters: ->
    lastSelectionExtent = @lastSelectionRange.getExtent()
    for selection in @editor.getSelections()
      {start} = selection.getBufferRange()
      newEnd = start.traverse(lastSelectionExtent)
      selection.setBufferRange([start, newEnd])
    return

class MoveLeft extends Motion
  @extend()
  moveCursor: (cursor) ->
    @countTimes ->
      if not cursor.isAtBeginningOfLine() or settings.get('wrapLeftRightMotion')
        cursor.moveLeft()

class MoveRight extends Motion
  @extend()
  composed: false

  onDidComposeBy: (operation) ->
    # Don't save oeration to instance variable to avoid reference before I understand it correctly.
    # Also introspection need to support circular reference detection to stop infinit reflection loop.
    @composed = true if operation.isOperator()

  isOperatorPending: ->
    @vimState.isOperatorPendingMode() or @composed

  moveCursor: (cursor) ->
    @countTimes =>
      wrapToNextLine = settings.get('wrapLeftRightMotion')

      # when the motion is combined with an operator, we will only wrap to the next line
      # if we are already at the end of the line (after the last character)
      if @isOperatorPending() and not cursor.isAtEndOfLine()
        wrapToNextLine = false

      cursor.moveRight() unless cursor.isAtEndOfLine()
      cursor.moveRight() if wrapToNextLine and cursor.isAtEndOfLine()

class MoveUp extends Motion
  @extend()
  linewise: true

  moveCursor: (cursor) ->
    @countTimes ->
      unless cursor.getScreenRow() is 0
        cursor.moveUp()

class MoveDown extends Motion
  @extend()
  linewise: true

  moveCursor: (cursor) ->
    @countTimes =>
      unless cursor.getScreenRow() is @editor.getLastScreenRow()
        cursor.moveDown()

class MoveToPreviousWord extends Motion
  @extend()
  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToBeginningOfWord()

class MoveToPreviousWholeWord extends Motion
  @extend()
  moveCursor: (cursor) ->
    @countTimes =>
      cursor.moveToBeginningOfWord()
      while not @isWholeWord(cursor) and not @isAtBeginningOfFile(cursor)
        cursor.moveToBeginningOfWord()

  isWholeWord: (cursor) ->
    char = cursor.getCurrentWordPrefix().slice(-1)
    AllWhitespace.test(char)

  isAtBeginningOfFile: (cursor) ->
    cursor.getBufferPosition().isEqual(Point.ZERO)

class MoveToNextWord extends Motion
  @extend()
  wordRegex: null

  moveCursor: (cursor, options) ->
    @countTimes =>
      current = cursor.getBufferPosition()

      next = if options?.excludeWhitespace
        cursor.getEndOfCurrentWordBufferPosition(wordRegex: @wordRegex)
      else
        cursor.getBeginningOfNextWordBufferPosition(wordRegex: @wordRegex)

      return if @isEndOfFile(cursor)

      if cursor.isAtEndOfLine()
        cursor.moveDown()
        cursor.moveToBeginningOfLine()
        cursor.skipLeadingWhitespace()
      else if current.row is next.row and current.column is next.column
        cursor.moveToEndOfWord()
      else
        cursor.setBufferPosition(next)

  isEndOfFile: (cursor) ->
    cur = cursor.getBufferPosition()
    eof = @editor.getEofBufferPosition()
    cur.row is eof.row and cur.column is eof.column

class MoveToNextWholeWord extends MoveToNextWord
  @extend()
  wordRegex: WholeWordOrEmptyLineRegex

class MoveToEndOfWord extends Motion
  @extend()
  wordRegex: null
  inclusive: true

  moveCursor: (cursor) ->
    @countTimes =>
      current = cursor.getBufferPosition()

      next = cursor.getEndOfCurrentWordBufferPosition(wordRegex: @wordRegex)
      next.column-- if next.column > 0

      if next.isEqual(current)
        cursor.moveRight()
        if cursor.isAtEndOfLine()
          cursor.moveDown()
          cursor.moveToBeginningOfLine()

        next = cursor.getEndOfCurrentWordBufferPosition(wordRegex: @wordRegex)
        next.column-- if next.column > 0

      cursor.setBufferPosition(next)

class MoveToEndOfWholeWord extends MoveToEndOfWord
  @extend()
  wordRegex: WholeWordRegex

class MoveToNextParagraph extends Motion
  @extend()

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToBeginningOfNextParagraph()

class MoveToPreviousParagraph extends Motion
  @extend()
  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToBeginningOfPreviousParagraph()

class MoveToBeginningOfLine extends Motion
  @extend()

  constructor: ->
    super

    # 0 is special need to differenciate `10`, 0
    # [NOTE] @getCount() depending on vimState, so we need to call super first.
    if @getCount()?
      @vimState.count.set(0)
      @abort()

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToBeginningOfLine()
      if settings.get('swapZeroWithHat')
        cursor.moveToFirstCharacterOfLine()

class MoveToFirstCharacterOfLine extends Motion
  @extend()

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToBeginningOfLine()
      unless settings.get('swapZeroWithHat')
        cursor.moveToFirstCharacterOfLine()

class MoveToFirstCharacterOfLineAndDown extends Motion
  @extend()
  linewise: true
  defaultCount: 0

  getCount: ->
    super - 1

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveDown()
    cursor.moveToBeginningOfLine()
    cursor.moveToFirstCharacterOfLine()

class MoveToLastCharacterOfLine extends Motion
  @extend()
  defaultCount: 1

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveToEndOfLine()
      cursor.goalColumn = Infinity

class MoveToLastNonblankCharacterOfLineAndDown extends Motion
  @extend()
  inclusive: true

  # moves cursor to the last non-whitespace character on the line
  # similar to skipLeadingWhitespace() in atom's cursor.coffee
  skipTrailingWhitespace: (cursor) ->
    position = cursor.getBufferPosition()
    scanRange = cursor.getCurrentLineBufferRange()
    startOfTrailingWhitespace = [scanRange.end.row, scanRange.end.column - 1]
    @editor.scanInBufferRange /[ \t]+$/, scanRange, ({range}) ->
      startOfTrailingWhitespace = range.start
      startOfTrailingWhitespace.column -= 1
    cursor.setBufferPosition(startOfTrailingWhitespace)

  getCount: ->
    super - 1

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveDown()
    @skipTrailingWhitespace(cursor)

class MoveToFirstCharacterOfLineUp extends Motion
  @extend()
  linewise: true

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveUp()
    cursor.moveToBeginningOfLine()
    cursor.moveToFirstCharacterOfLine()

class MoveToFirstCharacterOfLineDown extends Motion
  @extend()
  linewise: true

  moveCursor: (cursor) ->
    @countTimes ->
      cursor.moveDown()
    cursor.moveToBeginningOfLine()
    cursor.moveToFirstCharacterOfLine()

# Not directly used.
class MoveToLineBase extends Motion
  @extend()
  linewise: true

  getDestinationRow: (count) ->
    if count? then count - 1 else (@editor.getLineCount() - 1)

# keymap: G
class MoveToLine extends MoveToLineBase
  @extend()

  moveCursor: (cursor) ->
    cursor.setBufferPosition([@getDestinationRow(@getCount()), Infinity])
    cursor.moveToFirstCharacterOfLine()
    cursor.moveToEndOfLine() if cursor.getBufferColumn() is 0

# keymap: gg
class MoveToStartOfFile extends MoveToLineBase
  @extend()

  moveCursor: (cursor) ->
    {row, column} = @editor.getCursorBufferPosition()
    cursor.setBufferPosition([@getDestinationRow(@getCount(1)), 0])
    unless @isLinewise()
      cursor.moveToFirstCharacterOfLine()

class MoveToRelativeLine extends MoveToLineBase
  @extend()
  # ??  #783 delete line below accsidentally?
  linewise: true

  moveCursor: (cursor) ->
    {row, column} = cursor.getBufferPosition()
    cursor.setBufferPosition([row + (@getCount(1) - 1), 0])

# Not directly used.
class MoveToScreenLine extends MoveToLineBase
  @extend()
  scrolloff: 2

  moveCursor: (cursor) ->
    {row, column} = cursor.getBufferPosition()
    cursor.setScreenPosition([@getDestinationRow(), 0])

# keymap: H
class MoveToTopOfScreen extends MoveToScreenLine
  @extend()
  getDestinationRow: ->
    count = @getCount(0)
    firstScreenRow = @editorElement.getFirstVisibleScreenRow()
    if firstScreenRow > 0
      offset = Math.max(count - 1, @scrolloff)
    else
      offset = if count > 0 then count - 1 else count
    firstScreenRow + offset

# keymap: L
class MoveToBottomOfScreen extends MoveToScreenLine
  @extend()
  getDestinationRow: ->
    count = @getCount(0)
    lastScreenRow = @editorElement.getLastVisibleScreenRow()
    lastRow = @editor.getBuffer().getLastRow()
    if lastScreenRow isnt lastRow
      offset = Math.max(count - 1, @scrolloff)
    else
      offset = if count > 0 then count - 1 else count
    lastScreenRow - offset

# keymap: M
class MoveToMiddleOfScreen extends MoveToScreenLine
  @extend()
  getDestinationRow: ->
    firstScreenRow = @editorElement.getFirstVisibleScreenRow()
    lastScreenRow = @editorElement.getLastVisibleScreenRow()
    height = lastScreenRow - firstScreenRow
    Math.floor(firstScreenRow + (height / 2))

class ScrollKeepingCursor extends MoveToLineBase
  @extend()
  previousFirstScreenRow: 0
  currentFirstScreenRow: 0
  direction: null

  select: (options) ->
    finalDestination = @scrollScreen()
    super(options)
    @editor.setScrollTop(finalDestination)

  execute: ->
    finalDestination = @scrollScreen()
    super
    @editor.setScrollTop(finalDestination)

  moveCursor: (cursor) ->
    cursor.setScreenPosition([@getDestinationRow(@getCount(1)), 0])

  getDestinationRow: ->
    {row, column} = @editor.getCursorScreenPosition()
    @currentFirstScreenRow - @previousFirstScreenRow + row

  scrollScreen: ->
    @previousFirstScreenRow = @editorElement.getFirstVisibleScreenRow()

    amountPx = @getCount(1) * @getAmountInPixel()
    destination =
      if @direction is 'up'
        @editor.getScrollTop() - amountPx
      else if @direction is 'down'
        @editor.getScrollTop() + amountPx

    @editor.setScrollTop(destination)
    @currentFirstScreenRow = @editorElement.getFirstVisibleScreenRow()
    destination

  getHalfScreenPixel: ->
    Math.floor(@editor.getRowsPerPage() / 2) * @editor.getLineHeightInPixels()

# keymap: ctrl-u
class ScrollHalfScreenUp extends ScrollKeepingCursor
  @extend()
  direction: 'up'
  getAmountInPixel: ->
    @getHalfScreenPixel()

# keymap: ctrl-d
class ScrollHalfScreenDown extends ScrollHalfScreenUp
  @extend()
  direction: 'down'

# keymap: ctrl-b
class ScrollFullScreenUp extends ScrollKeepingCursor
  @extend()
  direction: 'up'
  getAmountInPixel: ->
    @editor.getHeight()

# keymap: ctrl-f
class ScrollFullScreenDown extends ScrollFullScreenUp
  @extend()
  direction: 'down'

# Find Motion
# -------------------------
# keymap: f
class Find extends Motion
  @extend()
  backwards: false
  complete: false
  repeated: false
  reverse: false
  offset: 0
  hoverText: ':mag_right:'
  hoverIcon: ':find:'
  requireInput: true
  inclusive: true

  constructor: ->
    super
    unless @repeated
      @getInput()

  match: (cursor, count) ->
    currentPosition = cursor.getBufferPosition()
    line = @editor.lineTextForBufferRow(currentPosition.row)
    if @backwards
      index = currentPosition.column
      for i in [0..count-1]
        return if index <= 0 # we can't move backwards any further, quick return
        index = line.lastIndexOf(@input, index-1-(@offset*@repeated))
      if index >= 0
        new Point(currentPosition.row, index + @offset)
    else
      index = currentPosition.column
      for i in [0..count-1]
        index = line.indexOf(@input, index+1+(@offset*@repeated))
        return if index < 0 # no match found
      if index >= 0
        new Point(currentPosition.row, index - @offset)

  moveCursor: (cursor) ->
    if (match = @match(cursor, @getCount(1)))?
      cursor.setBufferPosition(match)

    if @context
      @backwards = not @backwards if @reverse
    else
      @vimState.globalVimState.currentFind = this

# [FIXME] there is more better way to implement RepeatFind, RepeatFindReverse
# Current implementation is not declarative.
class RepeatFind extends Find
  @extend()
  repeated: true
  reverse: false
  offset: 0

  constructor: ->
    super
    @context = @vimState.globalVimState.currentFind
    @abort() unless @context
    {@offset, @backwards, @complete, @input} = @vimState.globalVimState.currentFind

  moveCursor: (args...) ->
    @context.moveCursor.apply(this, args)

class RepeatFindReverse extends RepeatFind
  @extend()
  reverse: true

  constructor: ->
    super
    @backwards = not @backwards

# keymap: F
class FindBackwards extends Find
  @extend()
  backwards: true
  hoverText: ':mag:'
  hoverIcon: ':find:'

# keymap: t
class Till extends Find
  @extend()
  offset: 1

  match: ->
    @selectAtLeastOne = false
    retval = super
    if retval? and not @backwards
      @selectAtLeastOne = true
    retval

  selectInclusive: (selection, options) ->
    super
    if selection.isEmpty() and @selectAtLeastOne
      selection.modifySelection ->
        selection.cursor.moveRight()

# keymap: T
class TillBackwards extends Till
  @extend()
  backwards: true

# Mark
# -------------------------
# keymap: '
class MoveToMark extends Motion
  @extend()
  linewise: true
  complete: false
  requireInput: true
  hoverText: ":round_pushpin:'"
  hoverIcon: ":move-to-mark:'"
  # hoverChar: "'"

  constructor: ->
    super
    # @vimState.hover.add @hoverChar
    @getInput()

  isLinewise: ->
    @linewise

  moveCursor: (cursor) ->
    markPosition = @vimState.mark.get(@input)

    if @input is '`' # double '`' pressed
      markPosition ?= [0, 0] # if markPosition not set, go to the beginning of the file
      @vimState.mark.set('`', cursor.getBufferPosition())

    cursor.setBufferPosition(markPosition) if markPosition?
    if @linewise
      cursor.moveToFirstCharacterOfLine()

# keymap: `
class MoveToMarkLiteral extends MoveToMark
  @extend()
  linewise: false
  hoverText: ":round_pushpin:`"
  hoverIcon: ":move-to-mark:"
  # hoverChar: '`'

# Search
# -------------------------
# class SearchBase extends MotionWithInput
class SearchBase extends Motion
  @extend()
  dontUpdateCurrentSearch: false
  complete: false

  constructor: ->
    super
    @reverse = @initiallyReversed = false
    @updateCurrentSearch() unless @dontUpdateCurrentSearch

  reversed: =>
    @initiallyReversed = @reverse = true
    @updateCurrentSearch()
    this

  moveCursor: (cursor) ->
    ranges = @scan(cursor)
    if ranges.length > 0
      range = ranges[(@getCount(1) - 1) % ranges.length]
      cursor.setBufferPosition(range.start)
    else
      atom.beep()

  scan: (cursor) ->
    return [] if @input is ""

    currentPosition = cursor.getBufferPosition()

    [rangesBefore, rangesAfter] = [[], []]
    @editor.scan @getSearchTerm(@input), ({range}) =>
      isBefore = if @reverse
        range.start.compare(currentPosition) < 0
      else
        range.start.compare(currentPosition) <= 0

      if isBefore
        rangesBefore.push(range)
      else
        rangesAfter.push(range)

    if @reverse
      rangesAfter.concat(rangesBefore).reverse()
    else
      rangesAfter.concat(rangesBefore)

  getSearchTerm: (term) ->
    modifiers = {'g': true}

    if not term.match('[A-Z]') and settings.get('useSmartcaseForSearch')
      modifiers['i'] = true

    if term.indexOf('\\c') >= 0
      term = term.replace('\\c', '')
      modifiers['i'] = true

    modFlags = Object.keys(modifiers).join('')

    try
      new RegExp(term, modFlags)
    catch
      new RegExp(_.escapeRegExp(term), modFlags)

  updateCurrentSearch: ->
    @vimState.globalVimState.currentSearch.reverse = @reverse
    @vimState.globalVimState.currentSearch.initiallyReversed = @initiallyReversed

  replicateCurrentSearch: ->
    @reverse = @vimState.globalVimState.currentSearch.reverse
    @initiallyReversed = @vimState.globalVimState.currentSearch.initiallyReversed

# keymap: /
class Search extends SearchBase
  @extend()
  constructor: ->
    super
    @getInput()

  getInput: ->
    viewModel = new SearchViewModel(this)
    viewModel.onDidGetInput (@input) =>
      @complete = true
      @vimState.operationStack.process() # Re-process!!

# keymap: ?
class ReverseSearch extends Search
  @extend()
  constructor: ->
    super
    @reversed()

# keymap: *
class SearchCurrentWord extends SearchBase
  @extend()
  @keywordRegex: null
  complete: true

  constructor: ->
    super

    # FIXME: This must depend on the current language
    defaultIsKeyword = "[@a-zA-Z0-9_\-]+"
    userIsKeyword = atom.config.get('vim-mode.iskeyword')
    @keywordRegex = new RegExp(userIsKeyword or defaultIsKeyword)

    searchString = @getCurrentWordMatch()
    @input = searchString
    @vimState.pushSearchHistory(searchString) unless searchString is @vimState.getSearchHistoryItem()

  getCurrentWord: ->
    cursor = @editor.getLastCursor()
    wordStart = cursor.getBeginningOfCurrentWordBufferPosition(wordRegex: @keywordRegex, allowPrevious: false)
    wordEnd   = cursor.getEndOfCurrentWordBufferPosition      (wordRegex: @keywordRegex, allowNext: false)
    cursorPosition = cursor.getBufferPosition()

    if wordEnd.column is cursorPosition.column
      # either we don't have a current word, or it ends on cursor, i.e. precedes it, so look for the next one
      wordEnd = cursor.getEndOfCurrentWordBufferPosition      (wordRegex: @keywordRegex, allowNext: true)
      return "" if wordEnd.row isnt cursorPosition.row # don't look beyond the current line

      cursor.setBufferPosition wordEnd
      wordStart = cursor.getBeginningOfCurrentWordBufferPosition(wordRegex: @keywordRegex, allowPrevious: false)

    cursor.setBufferPosition wordStart

    @editor.getTextInBufferRange([wordStart, wordEnd])

  cursorIsOnEOF: (cursor) ->
    pos = cursor.getNextWordBoundaryBufferPosition(wordRegex: @keywordRegex)
    eofPos = @editor.getEofBufferPosition()
    pos.row is eofPos.row and pos.column is eofPos.column

  getCurrentWordMatch: ->
    characters = @getCurrentWord()
    if characters.length > 0
      if /\W/.test(characters) then "#{characters}\\b" else "\\b#{characters}\\b"
    else
      characters

  execute: ->
    super() if @input.length > 0

# keymap: #
class ReverseSearchCurrentWord extends SearchCurrentWord
  @extend()
  constructor: ->
    super
    @reversed()

OpenBrackets = ['(', '{', '[']
CloseBrackets = [')', '}', ']']
AnyBracket = new RegExp(OpenBrackets.concat(CloseBrackets).map(_.escapeRegExp).join("|"))

# keymap: n
class RepeatSearch extends SearchBase
  @extend()
  complete: true
  dontUpdateCurrentSearch: true

  constructor: ->
    super
    @input = @vimState.getSearchHistoryItem(0) ? ''
    @replicateCurrentSearch()

  reversed: ->
    @reverse = not @initiallyReversed
    this

# keymap: N
class RepeatSearchBackwards extends RepeatSearch
  @extend()
  constructor: ->
    super
    @reversed()

# keymap: %
class BracketMatchingMotion extends SearchBase
  @extend()
  inclusive: true
  complete: true

  searchForMatch: (startPosition, reverse, inCharacter, outCharacter) ->
    depth = 0
    point = startPosition.copy()
    lineLength = @editor.lineTextForBufferRow(point.row).length
    eofPosition = @editor.getEofBufferPosition().translate([0, 1])
    increment = if reverse then -1 else 1

    loop
      character = @characterAt(point)
      depth++ if character is inCharacter
      depth-- if character is outCharacter

      return point if depth is 0

      point.column += increment

      return null if depth < 0
      return null if point.isEqual([0, -1])
      return null if point.isEqual(eofPosition)

      if point.column < 0
        point.row--
        lineLength = @editor.lineTextForBufferRow(point.row).length
        point.column = lineLength - 1
      else if point.column >= lineLength
        point.row++
        lineLength = @editor.lineTextForBufferRow(point.row).length
        point.column = 0

  characterAt: (position) ->
    @editor.getTextInBufferRange([position, position.translate([0, 1])])

  getSearchData: (position) ->
    character = @characterAt(position)
    if (index = OpenBrackets.indexOf(character)) >= 0
      [character, CloseBrackets[index], false]
    else if (index = CloseBrackets.indexOf(character)) >= 0
      [character, OpenBrackets[index], true]
    else
      []

  moveCursor: (cursor) ->
    startPosition = cursor.getBufferPosition()

    [inCharacter, outCharacter, reverse] = @getSearchData(startPosition)

    unless inCharacter?
      restOfLine = [startPosition, [startPosition.row, Infinity]]
      @editor.scanInBufferRange AnyBracket, restOfLine, ({range, stop}) ->
        startPosition = range.start
        stop()

    [inCharacter, outCharacter, reverse] = @getSearchData(startPosition)

    return unless inCharacter?

    if matchPosition = @searchForMatch(startPosition, reverse, inCharacter, outCharacter)
      cursor.setBufferPosition(matchPosition)

# Alias
module.exports = {
  CurrentSelection
  MoveLeft, MoveRight, MoveUp, MoveDown
  MoveToPreviousWord, MoveToNextWord, MoveToEndOfWord
  MoveToPreviousWholeWord, MoveToNextWholeWord, MoveToEndOfWholeWord
  MoveToNextParagraph, MoveToPreviousParagraph
  MoveToLine,
  MoveToRelativeLine, MoveToBeginningOfLine
  MoveToFirstCharacterOfLine, MoveToFirstCharacterOfLineUp
  MoveToLastCharacterOfLine, MoveToFirstCharacterOfLineDown
  MoveToFirstCharacterOfLineAndDown, MoveToLastNonblankCharacterOfLineAndDown
  MoveToStartOfFile,
  MoveToTopOfScreen, MoveToBottomOfScreen, MoveToMiddleOfScreen,

  # Aliased
  ScrollHalfScreenUp
  ScrollHalfScreenDown
  ScrollFullScreenUp
  ScrollFullScreenDown

  Find
  RepeatFind
  RepeatFindReverse
  FindBackwards
  Till
  TillBackwards
  MoveToMark
  MoveToMarkLiteral
  Search
  ReverseSearch
  SearchCurrentWord
  ReverseSearchCurrentWord
  BracketMatchingMotion
  RepeatSearch
  RepeatSearchBackwards
}