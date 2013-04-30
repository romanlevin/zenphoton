#!/usr/bin/env coffee
#
#   Queue runner: This is a daemon that sits on any machine with
#   CPU power and a connection to the internet. It waits on render
#   jobs to arrive on an Amazon SQS message queue.
#
#   AWS configuration comes from the environment:
#
#      AWS_ACCESS_KEY_ID
#      AWS_SECRET_ACCESS_KEY
#      AWS_REGION
#
#   Required Node modules:
#
#      npm install aws-sdk coffee-script async
#
#   This accepts JSON messages on an SQS queue. These messages are
#   objects with the following members:
#
#      SceneBucket:     S3 bucket for scene data
#      SceneKey:        S3 key for scene data
#      SceneIndex:      Optional array index in scene JSON data
#      OutputBucket:    S3 bucket for output data
#      OutputKey:       S3 key for output data
#      OutputQueueUrl:  SQS QueueUrl to post completion messages to
#
#   On completion, a superset of the above JSON will be sent back
#   to the output queue.
#
######################################################################
#
#   This file is part of HQZ, the batch renderer for Zen Photon Garden.
#
#   Copyright (c) 2013 Micah Elizabeth Scott <micah@scanlime.org>
#
#   Permission is hereby granted, free of charge, to any person
#   obtaining a copy of this software and associated documentation
#   files (the "Software"), to deal in the Software without
#   restriction, including without limitation the rights to use,
#   copy, modify, merge, publish, distribute, sublicense, and/or sell
#   copies of the Software, and to permit persons to whom the
#   Software is furnished to do so, subject to the following
#   conditions:
#
#   The above copyright notice and this permission notice shall be
#   included in all copies or substantial portions of the Software.
#
#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
#   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
#   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#   OTHER DEALINGS IN THE SOFTWARE.
#

AWS = require 'aws-sdk'
async = require 'async'
util = require 'util'
child_process = require 'child_process'
os = require 'os'

AWS.config.maxRetries = 50
sqs = new AWS.SQS({ apiVersion: '2012-11-05' }).client
s3 = new AWS.S3({ apiVersion: '2006-03-01' }).client
numCPUs = require('os').cpus().length

kHeartbeatSeconds = 30
kHQZ = './hqz'


class Runner
    run: (queueName, cb) ->
        sqs.createQueue
            QueueName: queueName
            (error, data) =>
                if error
                    cb error
                if data
                    @queue = data.QueueUrl
                    @numRunning = 0
                    @numRequested = 0
                    @lookForWork()

    lookForWork: ->
        # How much work do we need? We never want to run more jobs than we have CPU cores.
        # Keep track of how many jobs we're actually running as well as all of the potential
        # jobs represented by outstanding sqs.receiveMessage() requests. Only issue more requests
        # if we have the capacity to handle what we get back.

        return if @numRequested
        count = Math.min 10, numCPUs - @numRunning
        msg = "[ #{ @numRunning } of #{ numCPUs } processes running ]"
        return log msg if count <= 0
        log msg + " -- Looking for work..."

        @numRequested += count

        sqs.receiveMessage
            QueueUrl: @queue
            MaxNumberOfMessages: count
            VisibilityTimeout: kHeartbeatSeconds * 2
            WaitTimeSeconds: 10

            (error, data) =>
                @numRequested -= count

                return log "Error reading queue: " + util.inspect error if error
                if data and data.Messages

                    # Process incoming messages in parallel, report errors to console.
                    # Keep track of how many CPU cores are in use.

                    for m in data.Messages
                        do (m) =>
                            @numRunning += 1
                            m._running = true
                            @handleMessage m, (error) => @messageComplete(error, m)

                # Keep looking for work as long as we have idle CPU cores
                @lookForWork()

    handleMessage: (m, cb) ->
        try
            handler = new MessageHandler @queue, m, JSON.parse m.Body
            handler.start cb
        catch error
            cb error

    messageComplete: (error, m) ->
        log "Error processing message: " + util.inspect error if error
        if m._running
            # Only decrement after the first error.
            @numRunning -= 1
            m._running = false        
        @lookForWork()


class MessageHandler
    constructor: (@queue, @envelope, @msg) ->
        @msg.Hostname = os.hostname()
        @msg.ReceivedTime = (new Date).toJSON()
        @msg.State = 'received'

    start: (asyncCb) ->
        # Start handling the message. Callback reports errors, and it reports
        # completion of the CPU-hungry portion of the message. Once the rendering
        # is done and we're uploading results, this continues on asynchronously
        # to make this handler's slot available to another message.

        async.waterfall [

            (cb) =>
                # Download scene data
                s3.getObject
                    Bucket: @msg.SceneBucket
                    Key: @msg.SceneKey
                    cb

            (data, cb) =>
                # Store downloaded scene
                @scene = JSON.parse data.Body
                if @msg.SceneIndex >= 0
                    @scene = @scene[@msg.SceneIndex]

                log "Starting work on #{ @msg.SceneKey }"
                @msg.StartedTime = (new Date).toJSON()
                @msg.State = 'started'

                # Asynchronously let the world know we've started
                sqs.sendMessage
                    QueueUrl: @msg.OutputQueueUrl
                    MessageBody: JSON.stringify @msg
                    (error, data) => cb error if error

                # Start a watchdog, reminding us to refresh this message's visibility timer
                @watchdog = setInterval (() => @heartbeat()), kHeartbeatSeconds * 1000

                # Ask the child process to render the scene
                @runChildProcess cb

            (data, cb) =>
                # Upload finished scene
                log "Finished #{@msg.SceneKey}, uploading results to #{@msg.OutputKey}"
                @msg.FinishTime = (new Date).toJSON()
                @msg.State = 'finished'

                s3.putObject
                    Bucket: @msg.OutputBucket
                    Key: @msg.OutputKey
                    ContentType: 'image/png'
                    Body: data
                    cb

                # Let another message start running
                asyncCb()

            (data, cb) =>
                # Send final state change message after upload finishes

                @msg.UploadedTime = (new Date).toJSON()
                sqs.sendMessage
                    QueueUrl: @msg.OutputQueueUrl
                    MessageBody: JSON.stringify @msg
                    cb

            (data, cb) =>
                # Done, we can delete the message now!

                @cancelWatchdog()
                sqs.deleteMessage
                    QueueUrl: @queue
                    ReceiptHandle: @envelope.ReceiptHandle
                    cb

            (data, cb) =>
                # Finished!
                log "Finalized #{@msg.SceneKey} in #{@elapsedTime()} seconds"
                cb()

        ], (error) =>
            @cancelWatchdog
            asyncCb error if error

    elapsedTime: () ->
        0.001 * ((new Date).getTime() - Date.parse(@msg.StartedTime))

    cancelWatchdog: () ->
        clearInterval @watchdog if @watchdog
        @watchdog = null

    runChildProcess: (cb) ->
        # Invokes callback with rendered image data after child process completes.

        @output = []
        @child = child_process.spawn kHQZ, ['-', '-'],
            env: '{}'
            stdio: ['pipe', 'pipe', process.stderr]

        @child.stdout.on 'data', (data) =>
            @output.push data

        @child.on 'exit', (code, signal) =>
            return cb "Render process exited with code " + code if code != 0
            @child = null
            cb null, bufferConcat @output

        @child.stdin.write JSON.stringify @scene
        @child.stdin.end()

    heartbeat: ->
        # Periodically we need to reset our SQS message visibility timeout, so that
        # other nodes know we're still working on this job.

        log "Still working on #{ @msg.SceneKey } (#{ @elapsedTime() } seconds)"
        sqs.changeMessageVisibility
            QueueUrl: @queue
            ReceiptHandle: @envelope.ReceiptHandle
            VisibilityTimeout: kHeartbeatSeconds * 2
            (error) =>
                log "Error delivering heartbeat to #{ @msg.SceneKey }: #{ util.inspect error }" if error


log = (msg) ->
    console.log "[#{ (new Date).toJSON() }] #{msg}"


bufferConcat = (list) ->
    # Just like Buffer.concat(), but compatible with older versions of node.js
    size = 0
    for buf in list
        size += buf.length
    result = new Buffer size
    offset = 0
    for buf in list
        buf.copy(result, offset)
        offset += buf.length
    return result


qr = new Runner
qr.run "zenphoton-hqz-render-queue", (error) ->
    console.log util.inspect error
    process.exit 1
