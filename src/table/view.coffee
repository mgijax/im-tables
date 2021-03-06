do ->

    NUMERIC_TYPES = ["int", "Integer", "double", "Double", "float", "Float"]

    class Page
        constructor: (@start, @size) ->
        end: -> @start + @size
        all: -> !@size
        toString: () -> "Page(#{ @start}, #{ @size })"

    class ResultsTable extends Backbone.View

        @nextDirections =
            ASC: "DESC"
            DESC: "ASC"
        className: "im-results-table table table-striped table-bordered"
        tagName: "table"
        attributes:
          width: "100%"
          cellpadding: 0
          border: 0
          cellspacing: 0
        pageSize: 25
        pageStart: 0
        throbber: _.template """
          <tr class="im-table-throbber">
            <td colspan="<%= colcount %>">
              <h2>Requesting Data</h2>
              <div class="progress progress-info progress-striped active">
                <div class="bar" style="width: 100%"></div>
              </div>
            </td>
          </tr>
        """

        initialize: (@query, @getData, @columnHeaders) ->
            @columnHeaders ?= new Backbone.Collection
            @blacklistedFormatters = []
            @minimisedCols = {}
            @query.on "set:sortorder", (oes) =>
                @lastAction = 'resort'
                @fill()
            @query.on 'columnvis:toggle', (view) =>
              @minimisedCols[view] = not @minimisedCols[view]
              @query.trigger 'change:minimisedCols', _.extend {}, @minimisedCols
              @fill()
            @query.on "formatter:blacklist", (path, formatter) =>
              @blacklistedFormatters.push formatter
              @fill().then @addColumnHeaders

        changePageSize: (newSize) ->
            @pageSize = newSize
            @pageStart = 0 if (newSize is 0)
            @fill()

        render: ->
            @$el.empty()
            @$el.append document.createElement 'thead'
            @$el.append document.createElement 'tbody'
            promise = @fill()
            promise.done(@addColumnHeaders)

        goTo: (start) ->
            @pageStart = parseInt(start, 10)
            @fill()

        goToPage: (page) ->
            @pageStart = page * @pageSize
            @fill()

        fill: () ->
            promise = @getData(@pageStart, @pageSize).then @readHeaderInfo
            promise.done @appendRows
            promise.fail @handleError
            promise.done () =>
                @query.trigger "imtable:change:page", @pageStart, @pageSize
            promise

        handleEmptyTable: () ->
            apology = _.template intermine.snippets.table.NoResults @query
            @$el.append apology
            @$el.find('.btn-primary').click => @query.trigger 'undo'

        appendRows: (res) =>
          previousCells = (@currentCells || []).slice()
          for cell in previousCells
            cell.remove()
          if res.rows.length is 0
            @$("tbody > tr").remove()
            @handleEmptyTable()
          else
            docfrag = document.createDocumentFragment()
            for row in res.rows
              @appendRow docfrag, row
            @currentCells = res.rows.reduce ((a, r) -> a.concat(r)), []
            # Careful - there might be subtables out there - be specific.
            @$el.children('tbody').html docfrag

          @query.trigger "table:filled"

        minimisedColumnPlaceholder: _.template """
            <td class="im-minimised-col" style="width:<%= width %>px">&hellip;</td>
        """
        
        readHeaderInfo: (res) =>
          if res?.results?[0]
            @getEffectiveView(res.results[0]).then => res
          else
            res

        appendRow: (tbody, row) =>
            tr = document.createElement 'tr'
            tbody.appendChild tr
            minWidth = 10
            minimised = (k for k, v of @minimisedCols when v)
            replacer_of = {}
            processed = {}
            @columnHeaders.each (col) ->
              for r in (rs = col.get('replaces'))
                replacer_of[r] = col

            for cell, i in row then do (cell, i) =>
              return if processed[cell.path]
              processed[cell.path] = true
              {replaces, formatter, path} = (replacer_of[cell.path]?.toJSON() ? {})
              if replaces?.length > 1
                # Only accept if it is the right type, since formatters expect a type.
                return unless path.equals(cell.path.getParent())
                if formatter?.merge?
                  for c in row when _.any(replaces, (x) -> x.equals c.path)
                    formatter.merge(cell.model, c.model)

                processed[r] = true for r in replaces

              cell.formatter = formatter if formatter?

              if @minimisedCols[ cell.path ] or (path and @minimisedCols[path])
                $(tr).append @minimisedColumnPlaceholder width: minWidth
              else
                cell.render()
                tr.appendChild cell.el

        errorTempl: _.template """
            <div class="alert alert-error">
                <h2>Oops!</h2>
                <p><i><%- error %></i></p>
            </div>
        """

        handleError: (err, time) =>
            notice = $ @errorTempl error: err
            notice.append """<p>Time: #{ time }</p>""" if time?
            notice.append """<p>
                This is most likely related to the query that was just run. If you have
                time, please send us an email with details of this query to help us diagnose and
                fix this bug.
            </p>"""
            btn = $ '<button class="btn btn-error">'
            notice.append btn
            p = $ '<p style="display:none" class="well">'
            btn.text 'show query'
            p.text @query.toXML()
            btn.click () -> p.slideToggle()
            mailto = @query.service.help + "?" + $.param {
                subject: "Error running embedded table query"
                body: """
                    We encountered an error running a query from an
                    embedded result table.
                    
                    page:       #{ window.location }
                    service:    #{ @query.service.root }
                    error:      #{ err }
                    date-stamp: #{ time }
                    query:      #{ @query.toXML() }
                """
            }, true
            mailto = mailto.replace(/\+/g, '%20') # stupid jquery 'wontfix' indeed. grumble
            notice.append """<a class="btn btn-primary pull-right" href="mailto:#{ mailto }">
                    Email the help-desk
                </a>"""
            notice.append p
            @$el.append notice

        buildColumnHeader: (model, tr) -> #view, i, title, tr) ->
          header = new intermine.query.results.ColumnHeader {model, @query}
          header.render().$el.appendTo tr

        getEffectiveView: (row) -> @query.service.get("/classkeys").then ({classes}) =>
            q = @query
            classKeys = classes
            replacedBy = {}
            @columnHeaders.reset()
            {longestCommonPrefix, getReplacedTest} = intermine.utils

            # Create the columns
            cols = for cell in row
              path = q.getPathInfo cell.column
              replaces = if cell.view? # subtable of this cell.
                commonPrefix = longestCommonPrefix cell.view
                path = q.getPathInfo commonPrefix
                replaces = (q.getPathInfo(v) for v in cell.view)
              else
                []
              {path, replaces}

            # Build the replacement information.
            for col in cols when col.path.isAttribute() and intermine.results.shouldFormat col.path
              p = col.path
              formatter = intermine.results.getFormatter p
              unless formatter in @blacklistedFormatters
                col.isFormatted = true
                col.formatter = formatter
                for r in (formatter.replaces ? [])
                  subPath = "#{ p.getParent() }.#{ r }"
                  replacedBy[subPath] ?= col
                  col.replaces.push q.getPathInfo subPath if subPath in q.views

            isKeyField = (col) ->
              return false unless col.path.isAttribute()
              pType = col.path.getParent().getType().name
              fName = col.path.end.name
              return "#{pType}.#{fName}" in (classKeys?[pType] ? [])

            explicitReplacements = {}
            for col in cols
              for r in col.replaces
                explicitReplacements[r] = col

            isReplaced = getReplacedTest replacedBy, explicitReplacements

            for col in cols when not isReplaced col
              if col.isFormatted
                col.replaces.push col.path unless col.path in col.replaces
                col.path = col.path.getParent() if (isKeyField(col) or col.replaces.length > 1)

              @columnHeaders.add col

        # Read the result returned from the service, and add headers for 
        # the columns it represents to the table.
        addColumnHeaders: =>
          docfrag = document.createDocumentFragment()
          tr = document.createElement 'tr'
          docfrag.appendChild tr

          @columnHeaders.each (model) => @buildColumnHeader model, tr
                  
          @$el.children('thead').html docfrag

    class PageSizer extends Backbone.View

        tagName: 'form'
        className: "im-page-sizer form-horizontal"
        sizes: [[10], [25], [50], [100], [250]] # [0, 'All']]

        initialize: (@query, @pageSize) ->
            if @pageSize?
                unless _.include @sizes.map( (s) -> s[0] ), @pageSize
                    @sizes.unshift [@pageSize, @pageSize]
            else
                @pageSize = @sizes[0][0]
            @query.on 'page-size:revert', (size) => @$('select').val size

        events:
          "change select": "changePageSize"

        changePageSize: (evt) ->
          @query.trigger "page-size:selected", parseInt($(evt.target).val(), 10)

        render: () ->
          @$el.append """
              <label>
                  <span class="im-only-widescreen">Rows per page:</span>
                  <select class="span" title="Rows per page">
                  </select>
              </label>
          """
          select = @$('select')
          for ps in @sizes
              select.append @make 'option', {value: ps[0], selected: ps[0] is @pageSize}, (ps[1] or ps[0])
          this

    class Table extends Backbone.View

        className: "im-table-container"

        events:
            'submit .im-page-form': 'pageFormSubmit'
            'click .im-pagination-button': 'pageButtonClick'

        onDraw: =>
            @query.trigger("start:list-creation") if @__selecting
            @drawn = true

        refresh: =>
            @query.__changed = (@query.__changed or 0) + 1
            @table?.remove()
            @drawn = false
            @render()

        remove: ->
          @table?.remove()
          super()

        # @param query The query this view is bound to.
        # @param selector Where to put this table.
        initialize: (@query, selector, @columnHeaders) ->
            @cache = {}
            @itemModels = {}
            @_pipe_factor = 10
            @$parent = jQuery(selector)
            @__selecting = false
            @visibleViews = @query.views.slice()

            @query.on "start:list-creation", => @__selecting = true
            @query.on "stop:list-creation", => @__selecting = false

            @query.on "table:filled", @onDraw

            @query.on 'page:forwards', () => @goForward 1
            @query.on 'page:backwards', () => @goBack 1
            @query.on "page-size:selected", @handlePageSizeSelection
            @query.on "add-filter-dialogue:please", () =>
                dialogue = new intermine.filters.NewFilterDialogue(@query)
                @$el.append dialogue.el
                dialogue.render().openDialogue()

            @query.on "download-menu:open", =>
              dialogue = new intermine.query.export.ExportDialogue @query
              @$el.append dialogue.render().el
              dialogue.show()

        pageSizeFeasibilityThreshold: 250

        # Check if the given size could be considered problematic
        #
        # A size if problematic if it is above the preset threshold, or if it 
        # is a request for all results, and we know that the count is large.
        # @param size The size to assess.
        aboveSizeThreshold: (size) ->
            if size >= @pageSizeFeasibilityThreshold
                return true
            if size is 0
                total = @cache.lastResult.iTotalRecords
                return total >= @pageSizeFeasibilityThreshold
            return false

        # If the new page size is potentially problematic, then check with the user
        # first, rolling back if they see sense. Otherwise, change the page size
        # without user interaction.
        # @param size the requested page size.
        handlePageSizeSelection: (size) =>
            if @aboveSizeThreshold size
              $really = $ intermine.snippets.table.LargeTableDisuader
              $really.find('.btn-primary').click => @table.changePageSize size
              $really.find('.btn').click -> $really.modal('hide')
              $really.find('.im-alternative-action').click (e) =>
                  @query.trigger($(e.target).data 'event') if $(e.target).data('event')
                  @query.trigger 'page-size:revert', @table.pageSize
              $really.on 'hidden', -> $really.remove()
              $really.appendTo(@el).modal().modal('show')
            else
              @table.changePageSize size
        
        # Set the sort order of a query so that it matches the parameters 
        # passed from DataTables.
        #
        # @param params An array of {name: x, value: y} objects passed from DT.
        #
        adjustSortOrder: (params) ->
            viewIndices = for i in [0 .. intermine.utils.getParameter(params, "iColumns")]
                intermine.utils.getParameter(params, "mDataProp_" + i)
            noOfSortColumns = intermine.utils.getParameter(params, "iSortingCols")
            if noOfSortColumns
                @query.orderBy (for i in [0 ... noOfSortColumns] then do (i) =>
                    displayed = intermine.utils.getParameter(params, "iSortCol_" + i)
                    so =
                        path: @query.views[viewIndices[displayed]]
                        direction: intermine.utils.getParameter(params, "sSortDir_" + i)
                    so)

        # Take a bad response and present the error somewhere visible to the user.
        # @param resp An ajax response.
        showError: (resp) =>
            try
                data = JSON.parse(resp.responseText)
                @table?.handleError(data.error, data.executionTime)
            catch err
                @table?.handleError("Internal error", new Date().toString())


        ##
        ## Function for buffering data for a request. Each request fetches a page of
        ## pipe_factor * size, and if subsequent requests request data within this range, then
        ##
        ## @param src URL passed from DataTables. Ignored.
        ## @param param list of {name: x, value: y} objects passed from DataTables
        ## @param callback fn of signature: resultSet -> ().
        ##
        ##
        getRowData: (start, size) => # params, callback) =>
            end = start + size
            isOutOfRange = false

            freshness = @query.getSorting() + @query.getConstraintXML() + @query.views.join()
            isStale = (freshness isnt @cache.freshness)

            if isStale
                ## Invalidate the cache
                @cache = {}
            else
                ## We need new data if the range of this request goes beyond that of the 
                ## cached values, or if all results are selected.
                isOutOfRange = @cache.lowerBound < 0 or
                    start < @cache.lowerBound or
                    end   > @cache.upperBound or
                    size  <= 0

            promise = new jQuery.Deferred()
            if isStale or isOutOfRange
                page = @getPage start, size
                @overlayTable()

                req = @query[@fetchMethod] {start: page.start, size: page.size}
                req.fail @showError
                req.done (rows, rs) =>
                    @addRowsToCache page, rs
                    @cache.freshness = freshness
                    promise.resolve @serveResultsFromCache start, size
                req.always @removeOverlay
            else
                promise.resolve @serveResultsFromCache start, size

            return promise

        overlayTable: =>
            return unless @table and @drawn
            elOffset = @$el.offset()
            tableOffset = @table.$el.offset()
            jQuery('.im-table-overlay').remove()
            @overlay = jQuery @make "div",
              class: "im-table-overlay discrete " + intermine.options.StylePrefix
            @overlay.css
                top: elOffset.top
                left: elOffset.left
                width: @table.$el.outerWidth(true)
                height: (tableOffset.top - elOffset.top) + @table.$el.outerHeight()
            @overlay.append @make "h1", {}, "Requesting data..."
            @overlay.find("h1").css
                top: (@table.$el.height() / 2) + "px"
                left: (@table.$el.width() / 4) + "px"
            @overlay.appendTo 'body'
            _.delay (=> @overlay.removeClass "discrete"), 100

        removeOverlay: => @overlay?.remove()

        ##
        ## Get the page to request given the desired start and size.
        ##
        ## @param start the index of the first result the user actually wants to see.
        ## @param size The size of the dislay window.
        ##
        ## @return A page object with "start" and "size" properties set to include the desired
        ##         results, but also taking the cache into account.
        ##
        getPage: (start, size) ->
            page = new Page(start, size)
            unless @cache.lastResult
                ## Can ignore the cache
                page.size *= @_pipe_factor
                return page

            # When paging backwards - extend page towards 0.
            if start < @cache.lowerBound
                page.start = Math.max 0, start - (size * @_pipe_factor)

            if size > 0
                page.size *= @_pipe_factor
            else
                page.size = '' ## understood by server as all.

            # TODO - don't fill in gaps when it is too big (for some configuration of too big!)
            # Don't permit gaps, if the query itself conforms with the cache.
            if page.size && (page.end() < @cache.lowerBound)
                if (@cache.lowerBound - page.end()) > (page.size * 10)
                    @cache = {} # dump cache
                    page.size *= 2
                    return page
                else
                    page.size = @cache.lowerBound - page.start

            if @cache.upperBound < page.start
                if (page.start - @cache.upperBound) > (page.size * 10)
                    @cache = {} # dump cache
                    page.size *= 2
                    page.start = Math.max(0, page.start - (size * @_pipe_factor))
                    return page
                if page.size
                    page.size += page.start - @cache.upperBound
                # Extend towards cache limit
                page.start = @cache.upperBound

            return page

        ##
        ## Update the cache with the retrieved results. If there is an overlap 
        ## between the returned results and what is already held in cache, prefer the newer 
        ## results.
        ##
        ## @param page The page these results were requested with.
        ## @param result The resultset returned from the server.
        ##
        ##
        addRowsToCache: (page, result) ->
            unless @cache.lastResult
                @cache.lastResult = result
                @cache.lowerBound = result.start
                @cache.upperBound = page.end()
            else
                rows = result.results
                merged = @cache.lastResult.results.slice()
                # Add rows we don't have to the front
                if page.start < @cache.lowerBound
                    merged = rows.concat merged.slice page.end() - @cache.lowerBound
                # Add rows we don't have to the end
                if @cache.upperBound < page.end() or page.all()
                    merged = merged.slice(0, (page.start - @cache.lowerBound)).concat(rows)

                @cache.lowerBound = Math.min @cache.lowerBound, page.start
                @cache.upperBound = @cache.lowerBound + merged.length #Math.max @cache.upperBound, page.end()
                @cache.lastResult.results = merged

        updateSummary: (start, size, result) ->
            summary = @$ '.im-table-summary'
            html    = intermine.snippets.table.CountSummary
                first: start + 1
                last: if (size is 0) then 0 else Math.min(start + size, result.iTotalRecords)
                count: intermine.utils.numToString(result.iTotalRecords, ",", 3)
                roots: "rows"
            summary.html html
            @query.trigger 'count:is', result.iTotalRecords

        ##
        ## Retrieve the results from the results cache.
        ##
        ## @param echo The results table request control.
        ## @param start The index of the first result desired.
        ## @param size The page size
        ##
        serveResultsFromCache: (start, size) ->
            base = @query.service.root.replace /\/service\/?$/, ""
            result = jQuery.extend true, {}, @cache.lastResult
            # Splice off the undesired sections.
            result.results.splice(0, start - @cache.lowerBound)
            result.results.splice(size, result.results.length) if (size > 0)

            @updateSummary start, size, result

            # TODO - make sure cells know their node...

            fields = ([@query.getPathInfo(v).getParent(), v.replace(/^.*\./, "")] for v in result.views)

            makeCell = (obj) =>
                if _.has(obj, 'rows')
                  node = @query.getPathInfo obj.column
                  return new intermine.results.table.SubTable
                    query: @query
                    cellify: makeCell
                    blacklistedFormatters: (@table?.blacklistedFormatters ? [])
                    mainTable: @
                    subtable: obj
                    node: node
                else
                  node = @query.getPathInfo(obj.column).getParent()
                  field = obj.column.replace(/^.*\./, '')
                  model = if obj.id?
                    @itemModels[obj.id] or= (new intermine.model.IMObject(obj, @query, field, base))
                  else if not obj.class?
                    type = node.getParent().name
                    new intermine.model.NullObject {}, {@query, field, type}
                  else
                    new intermine.model.FPObject({}, {@query, obj, field})
                  model.merge obj, field
                  args = {model, node, field}
                  args.query = @query
                  return new intermine.results.table.Cell(args)

            # When all mines support tablerows, this hack can be removed. TODO
            result.rows = result.results.map (row) =>
                (row).map (cell, idx) =>
                    if _.has(cell, 'column') # dealing with new-style tableRows here.
                        makeCell(cell)
                    else if cell?.id?
                        field = fields[idx]
                        imo = @itemModels[cell.id] or= (new intermine.model.IMObject(cell, @query, field[1], base))
                        imo.merge cell, field[1]
                        new intermine.results.table.Cell(
                            model: imo
                            node: field[0]
                            field: field[1]
                            query: @query
                        )
                    else if cell?.value?
                        new intermine.results.table.Cell( # FastPathObjects don't have ids, and cannot be in lists.
                            model: new intermine.model.FPObject(@query, cell, field[1])
                            query: @query
                            field: field[1]
                        )
                    else
                        new intermine.results.table.NullCell query: @query

            result

        tableAttrs:
            class: "table table-striped table-bordered"
            width: "100%"
            cellpadding: 0
            border: 0
            cellspacing: 0

        render: ->
            @$el.empty()

            tel = @make "table", @tableAttrs
            @$el.append tel
            jQuery(tel).append """
                <h2>Building table</h2>
                <div class="progress progress-striped active progress-info">
                    <div class="bar" style="width: 100%"></div>
                </div>
            """
            @query.service.fetchVersion(@doRender(tel)).fail @onSetupError(tel)

        doRender: (tel) -> (version) =>
            @fetchMethod = if version >= 10
                'tableRows'
            else
                'table'

            path = "query/results"
            setupParams =
                format: "jsontable"
                query: @query.toXML()
                token: @query.service.token
            @$el.appendTo @$parent
            @query.service.post(path, setupParams).then @onSetupSuccess(tel), @onSetupError(tel)
            this

        horizontalScroller: """
            <div class="scroll-bar-wrap well">
                <div class="scroll-bar-containment">
                    <div class="scroll-bar alert-info alert"></div>
                </div>
            </div>
        """

        placePagination: ($widgets) ->
            $pagination = $(intermine.snippets.table.Pagination).appendTo($widgets)
            $pagination.find('li').tooltip(placement: "top")
            currentPageButton = $pagination.find(".im-current-page a").click =>
                total = @cache.lastResult.iTotalRecords
                if @table.pageSize >= total
                    return false
                currentPageButton.hide()
                $pagination.find('form').show()

        placePageSizer: ($widgets) ->
            pageSizer = new PageSizer(@query, @pageSize)
            pageSizer.render().$el.appendTo $widgets

        placeScrollBar: ($widgets) ->
            if @bar is 'horizontal'
                $scrollwrapper = $(@horizontalScroller).appendTo($widgets)
                scrollbar = @$ '.scroll-bar'

                currentPos = 0
                scrollbar.draggable
                    axis: "x"
                    containment: "parent"
                    stop: (event, ui) =>
                        scrollbar.removeClass("scrolling")
                        scrollbar.tooltip("hide")
                        @table.goTo currentPos
                    start: -> $(this).addClass("scrolling")
                    drag: (event, ui) =>
                        scrollbar.tooltip("show")
                        left = ui.position.left
                        total = ui.helper.closest('.scroll-bar-wrap').width()
                        currentPos = @cache.lastResult.iTotalRecords * left / total

                scrollbar.css(position: "absolute").parent().css(position: "relative")

                scrollbar.tooltip
                    trigger: "manual"
                    title: => "#{(currentPos + 1).toFixed()} ... #{(currentPos + @table.pageSize).toFixed()}"

        placeTableSummary: ($widgets) ->
            $widgets.append """
                <span class="im-table-summary"></div>
            """

        onSetupSuccess: (telem) -> (result) =>
            $telem = jQuery(telem).empty()
            $widgets = $('<div>').insertBefore(telem)

            @table = new ResultsTable @query, @getRowData, @columnHeaders
            @table.setElement telem
            @table.pageSize = @pageSize if @pageSize?
            @table.pageStart = @pageStart if @pageStart?
            @table.render()
            @query.on "imtable:change:page", @updatePageDisplay

            for component in intermine.options.TableWidgets when "place#{ component }" of @
                method = "place#{ component }"
                @[ method ]( $widgets )

            $widgets.append """<div style="clear:both"></div>"""

        getCurrentPageSize: -> @table?.pageSize ? @pageSize

        getCurrentPage: () ->
            if @table.pageSize then Math.floor @table.pageStart / @table.pageSize else 0

        getMaxPage: () ->
            total = @cache.lastResult.iTotalRecords
            pageSize = @table.pageSize
            correction = if total % pageSize is 0 then -1 else 0

            Math.floor(total / pageSize) + correction

        goBack: (pages) -> @table.goTo Math.max 0, @table.pageStart - (pages * @table.pageSize)

        goForward: (pages) ->
            @table.goTo Math.min @getMaxPage() * @table.pageSize, @table.pageStart + (pages * @table.pageSize)

        pageButtonClick: (e) ->
            $elem = $(e.target)
            unless $elem.parent().is('.active') # Here active means "where we are"
                switch $elem.data("goto")
                    when "start" then @table.goTo(0)
                    when "prev" then  @goBack 1
                    when "fast-rewind" then @goBack 5
                    when "next" then @goForward 1
                    when "fast-forward" then @goForward 5
                    when "end" then @table.goTo @getMaxPage() * @table.pageSize

        updatePageDisplay: (start, size) =>
            total = @cache.lastResult.iTotalRecords
            if size is 0
                size = total

            scrollbar = @$ '.scroll-bar-wrap'
            if scrollbar.length
                totalWidth = scrollbar.width()
                proportion = size / total
                scrollbar.toggle size < total
                unit = totalWidth / total
                scaled = Math.max(totalWidth * proportion, 20)
                overhang = size - ((total - (size * Math.floor(total / size)) ) % size)
                scrollbar.find('.scroll-bar-containment').css width: totalWidth + (unit * overhang)
                handle = scrollbar.find('.scroll-bar').css width: scaled
                handle.animate
                    left: unit * start

            tbl = @table
            buttons = @$('.im-pagination-button')
            buttons.each ->
                $elem = $(@)
                li = $elem.parent()
                isActive = switch $elem.data("goto")
                    when "start", 'prev' then start is 0
                    when 'fast-rewind' then start is 0
                    when "next", 'end' then (start + size >= total)
                    when "fast-forward" then (start + (5 * size) >= total)
                li.toggleClass 'active', isActive

            centre = @$('.im-current-page')
            centre.find('a').text("p. #{@getCurrentPage() + 1}")
            centre.toggleClass "active", size >= total
            pageForm = centre.find('form')
            cg = pageForm.find('.control-group').empty().removeClass 'error'
            maxPage = @getMaxPage()
            if maxPage <= 100
                pageSelector = $('<select>').appendTo(cg)
                pageSelector.val @getCurrentPage()
                pageSelector.change (e) ->
                    e.stopPropagation()
                    e.preventDefault()
                    tbl.goToPage parseInt pageSelector.val()
                    centre.find('a').show()
                    pageForm.hide()
                for p in [1 .. maxPage + 1]
                    pageSelector.append """
                        <option value="#{p - 1}">p. #{p}</option>
                    """
            else
                cg.append("""<input type=text placeholder="go to page...">""")
                cg.append("""<button class="btn" type="submit">go</button>""")

        pageFormSubmit: (e) ->
            e.stopPropagation()
            e.preventDefault()
            pageForm = @$('.im-page-form')
            centre = @$('.im-current-page')
            inp = pageForm.find('input')
            if inp.size()
                destination = inp.val().replace(/\s*/g, "")
            	if destination.match /^\d+$/
                    newSelectorVal = Math.min @getMaxPage(), Math.max(parseInt(destination) - 1, 0)
                    @table.goToPage newSelectorVal
                    centre.find('a').show()
                    pageForm.hide()
            	else
                    pageForm.find('.control-group').addClass 'error'
                    inp.val ''
                    inp.attr placeholder: "1 .. #{ @getMaxPage() + 1 }"

        errorIntro = "Could not load the data-table."
        genericExplanation = """
                The server may be down, or 
                incorrectly configured, or 
                we could be pointed at an invalid URL.
        """
        badJson = "What we do know is that the server did not return a valid JSON response."

        onSetupError: (telem) -> (resp) =>
            $(telem).empty()
            console.error "SETUP FAILURE", arguments
            notice = @make "div", class: "alert alert-error"

            # Depending on the imjs version, we the xhr may have been parsed for us, or not.
            reasonStr = if text = resp?.responseText
              try
                  JSON?.parse(text).error or genericExplanation
              catch e
                  console.error text
                  genericExplanation + "\n" + badJson
            else if resp?
              String resp
            else
              genericExplanation

            reasons = reasonStr.split "\n"

            content = [@make("span", {}, errorIntro)]
            if reasons.length
              content.push @make "ul", {}, (@make "li", {}, issue for issue in reasons)

            $(notice).append(@make("a", {class: "close", "data-dismiss": "alert"}, "close"))
                     .append(@make("strong", {}, "Ooops...! "))
                     .append(content)
                     .appendTo(telem)

    scope "intermine.query.results", {Table}

