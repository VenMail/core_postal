class @IPSelector
  constructor: ->
    @bindEvents()

  bindEvents: ->
    $(document).on 'click', '.js-ip-selector-trigger', (e) =>
      e.preventDefault()
      @showModal($(e.currentTarget))

    $(document).on 'click', '.js-modal-close', (e) =>
      e.preventDefault()
      @hideModal()

    $(document).on 'click', '.js-ip-selector-submit', (e) =>
      e.preventDefault()
      @submitSelection($(e.currentTarget))

    $(document).on 'change', '.ipSelector__radio', (e) =>
      @updateSubmitButton()

  showModal: ($trigger) ->
    messageId = $trigger.data('message-id')
    $modal = $('.js-ip-selector-modal')
    
    # Reset any previous selections
    $modal.find('.ipSelector__radio').prop('checked', false)
    @updateSubmitButton()
    
    # Show modal
    $modal.removeClass('is-hidden')
    
    # Store message ID for later use
    $modal.data('message-id', messageId)

  hideModal: ->
    $('.js-ip-selector-modal').addClass('is-hidden')

  updateSubmitButton: ->
    selectedCount = $('.ipSelector__radio:checked').length
    $submitBtn = $('.js-ip-selector-submit')
    
    if selectedCount > 0
      $submitBtn.removeClass('button--disabled').prop('disabled', false)
    else
      $submitBtn.addClass('button--disabled').prop('disabled', true)

  submitSelection: ($submitBtn) ->
    $selectedRadio = $('.ipSelector__radio:checked')
    
    if $selectedRadio.length == 0
      alert('Please select an IP address')
      return

    messageId = $submitBtn.data('message-id')
    ipAddressId = $selectedRadio.val()
    selectedIP = $selectedRadio.data('ip')
    
    # Extract org/server permalinks from /org/:org/servers/:server/... paths
    pathSegments = window.location.pathname.split('/')
    orgPermalink = pathSegments[2]
    serverPermalink = pathSegments[4]
    
    # Disable button during request
    $submitBtn.prop('disabled', true).text('Retrying...')
    
    # Make AJAX request
    $.ajax
      url: "/org/#{orgPermalink}/servers/#{serverPermalink}/messages/#{messageId}/retry_with_ip"
      method: 'POST'
      data:
        ip_address_id: ipAddressId
      dataType: 'json'
      success: (data) =>
        @hideModal()
        # Show flash message
        if data.flash && data.flash.notice
          @showFlashMessage('notice', data.flash.notice)
        else if data.flash && data.flash.alert
          @showFlashMessage('alert', data.flash.alert)
        
        # Refresh the page to show updated status
        setTimeout(->
          window.location.reload()
        , 1000)
      
      error: (xhr) =>
        $submitBtn.prop('disabled', false).text('Retry with Selected IP')
        try
          errorData = JSON.parse(xhr.responseText)
          if errorData.flash && errorData.flash.alert
            @showFlashMessage('alert', errorData.flash.alert)
          else
            @showFlashMessage('alert', 'An error occurred while retrying the message')
        catch
          @showFlashMessage('alert', 'An error occurred while retrying the message')

  showFlashMessage: (type, message) ->
    # Remove existing flash messages
    $('.flash').remove()
    
    # Create new flash message
    $flash = $("<div class='flash flash--#{type}'>#{message}</div>")
    $('body').prepend($flash)
    
    # Auto-hide after 5 seconds
    setTimeout(->
      $flash.fadeOut(->
        $flash.remove()
      )
    , 5000)

# Initialize when DOM is ready
$ ->
  new IPSelector()
