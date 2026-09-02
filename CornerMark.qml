import QtQuick

Item {
  id: root

  property string fillColor: "#7A9E6A"
  property string dimColor: "#4E6A42"
  property string sheenColor: "#C5D6B8"
  property int markSize: 26

  width: markSize
  height: markSize

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      var s = width
      ctx.reset()
      ctx.clearRect(0, 0, s, s)

      ctx.beginPath()
      ctx.moveTo(s * 0.20, 0)
      ctx.lineTo(s, 0)
      ctx.lineTo(s, s * 0.80)
      ctx.closePath()

      var grad = ctx.createLinearGradient(s, 0, s * 0.22, s * 0.78)
      grad.addColorStop(0, root.fillColor)
      grad.addColorStop(1, root.dimColor)
      ctx.globalAlpha = 0.92
      ctx.fillStyle = grad
      ctx.fill()

      ctx.globalAlpha = 0.45
      ctx.beginPath()
      ctx.moveTo(s * 0.20, 0.7)
      ctx.lineTo(s - 0.7, s * 0.80)
      ctx.strokeStyle = root.sheenColor
      ctx.lineWidth = 1.2
      ctx.lineCap = "round"
      ctx.stroke()
      ctx.globalAlpha = 1
    }
  }

  onFillColorChanged: canvas.requestPaint()
  onDimColorChanged: canvas.requestPaint()
  onSheenColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
  Component.onCompleted: canvas.requestPaint()
}
