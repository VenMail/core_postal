class @RecallMessage
  constructor: ->
    @bindEvents()

  bindEvents: ->
    $(document).on 'click', '.js-recall-trigger', (e) =>
      e.preventDefault()
      @showModal($(e.currentTarget))

    $(document).on 'click', '.js-modal-close', (e) =>
      e.preventDefault()
      @hideModal()

    $(document).on 'click', '.js-recall-submit', (e) =>
      e.preventDefault()
      @submitRecall($(e.currentTarget))

    $(document).on 'submit', '.js-recall-form', (e) =>
      e.preventDefault()
      @submitRecall($(e.currentTarget).find('.js-recall-submit'))

    $(document).on 'input change', '.js-recall-form input, .js-recall-form textarea, .js-recall-form select', (e) =>
      @updateSubmitButton()

  showModal: ($trigger) ->
    messageId = $trigger.data('message-id')
    $modal = $('.js-recall-modal')
    
    # Reset form
    $modal.find('.js-recall-form')[0].reset()
    @updateSubmitButton()
    
    # Show modal
    $modal.removeClass('is-hidden')
    
    # Store message ID for later use
    $modal.data('message-id', messageId)

  hideModal: ->
    $('.js-recall-modal').addClass('is-hidden')

  updateSubmitButton: ->
    $form = $('.js-recall-form')
    $submitBtn = $('.js-recall-submit')
    
    # Check if all required fields are filled
    subject = $form.find('#recall_subject').val().trim()
    body = $form.find('#recall_body').val().trim()
    
    isValid = subject && body
    
    if isValid
      $submitBtn.removeClass('button--disabled').prop('disabled', false)
    else
      $submitBtn.addClass('button--disabled').prop('disabled', true)

  submitRecall: ($submitBtn) ->
    $form = $('.js-recall-form')
    $modal = $('.js-recall-modal')
    
    # Validate form
    formData = $form.serialize()
    if !formData.includes('recall%5Bsubject%5D=') || !formData.includes('recall%5Bbody%5D=')
      alert('Please fill in all required fields')
      return

    messageId = $modal.data('message-id')
    
    # Show loading state
    $modal.find('.recallForm__content').addClass('is-hidden')
    $modal.find('.recallForm__loading').removeClass('is-hidden')
    
    # Make AJAX request
    $.ajax
      url: $form.attr('action')
      method: $form.attr('method')
      data: formData
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
        # Hide loading state and show form again
        $modal.find('.recallForm__content').removeClass('is-hidden')
        $modal.find('.recallForm__loading').addClass('is-hidden')
        
        try
          errorData = JSON.parse(xhr.responseText)
          if errorData.flash && errorData.flash.alert
            @showFlashMessage('alert', errorData.flash.alert)
          else
            @showFlashMessage('alert', 'An error occurred while sending the recall notice')
        catch
          @showFlashMessage('alert', 'An error occurred while sending the recall notice')

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
  new RecallMessage()
