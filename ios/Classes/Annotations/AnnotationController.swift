//
//  AnnotationController.swift
//  apple_maps_flutter
//
//  Created by Luis Thein on 09.09.19.
//

import Foundation
import MapKit

extension AppleMapController: AnnotationDelegate {

    public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView)  {
        if #available(iOS 11.0, *),
           let cluster = view.annotation as? MKClusterAnnotation {
            mapView.deselectAnnotation(cluster, animated: false)
            self.zoomInto(cluster: cluster, on: mapView)
            return
        }
        if let annotation: FlutterAnnotation = view.annotation as? FlutterAnnotation  {
            self.currentlySelectedAnnotation = annotation.id
            if !annotation.selectedProgrammatically {
                if !self.isAnnotationInFront(zIndex: annotation.zIndex) {
                    self.moveToFront(annotation: annotation)
                }
                self.onAnnotationClick(annotation: annotation)
            } else {
                annotation.selectedProgrammatically = false
            }

            if annotation.infoWindowConsumesTapEvents {
                let tapGestureRecognizer = InfoWindowTapGestureRecognizer(target: self, action: #selector(onCalloutTapped))
                tapGestureRecognizer.annotationId = annotation.id
                tapGestureRecognizer.annotationView = view
                view.addGestureRecognizer(tapGestureRecognizer)
            }
        }
    }

    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            return nil
        } else if #available(iOS 11.0, *), let cluster = annotation as? MKClusterAnnotation {
            return self.getClusterAnnotationView(for: cluster)
        } else if let flutterAnnotation = annotation as? FlutterAnnotation {
            return self.getAnnotationView(annotation: flutterAnnotation)
        }
        return nil
    }

    @available(iOS 11.0, *)
    private func getClusterAnnotationView(for cluster: MKClusterAnnotation) -> MKAnnotationView {
        let identifier = "FlutterClusterAnnotationView"
        self.mapView.register(FlutterClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: identifier)
        let view = self.mapView.dequeueReusableAnnotationView(withIdentifier: identifier, for: cluster)
        view.annotation = cluster
        return view
    }

    @available(iOS 11.0, *)
    private func zoomInto(cluster: MKClusterAnnotation, on mapView: MKMapView) {
        let members = cluster.memberAnnotations
        guard !members.isEmpty else { return }
        var minLat = members[0].coordinate.latitude
        var maxLat = minLat
        var minLon = members[0].coordinate.longitude
        var maxLon = minLon
        for member in members {
            let c = member.coordinate
            if c.latitude < minLat { minLat = c.latitude }
            if c.latitude > maxLat { maxLat = c.latitude }
            if c.longitude < minLon { minLon = c.longitude }
            if c.longitude > maxLon { maxLon = c.longitude }
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // For very tight clusters (members within ~10m of one another) a
        // 0.01° minimum span would zoom out far enough that they re-cluster
        // immediately. Use a small minimum so MapKit zooms in close enough
        // for the pins to separate visually.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.0005),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.0005)
        )
        mapView.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
    }

    /// Reuse identifier keyed by the view *kind* (pin / marker / custom) plus
    /// its tint — deliberately NOT the annotation id.
    ///
    /// Keying on `annotation.id` (as this used to) gave every annotation its
    /// own reuse pool of one, so no view was ever recycled and
    /// `register(_:forAnnotationViewWithReuseIdentifier:)` ran once per unique
    /// id. With thousands of annotations clustering/declustering during
    /// zoom/pan that grew the registry and retained-view set without bound,
    /// degrading MKMapView's annotation/gesture handling until the platform
    /// view was recreated. Pin/marker tint is folded into the key so each pool
    /// is tint-homogeneous and the tint never needs re-applying on reuse;
    /// custom-image views share one pool and have their image refreshed on
    /// every call (see `applyAppearance`).
    private func reuseIdentifier(for annotation: FlutterAnnotation) -> String {
        switch annotation.icon.iconType {
        case .MARKER:
            if let hue = annotation.icon.hueColor { return "fmap.annotation.marker.\(hue)" }
            return "fmap.annotation.marker"
        case .CUSTOM_FROM_ASSET, .CUSTOM_FROM_BYTES:
            return "fmap.annotation.custom"
        case .PIN:
            if let hue = annotation.icon.hueColor { return "fmap.annotation.pin.\(hue)" }
            return "fmap.annotation.pin"
        }
    }

    /// Per-annotation visuals that differ between annotations sharing a reuse
    /// pool, refreshed on every `getAnnotationView` call so a recycled view
    /// never keeps the previous annotation's look. Tint is intentionally absent
    /// here: it's baked into the reuse identifier, so each pool is already
    /// tint-correct.
    private func applyAppearance(to view: MKAnnotationView, annotation: FlutterAnnotation) {
        switch annotation.icon.iconType {
        case .CUSTOM_FROM_ASSET, .CUSTOM_FROM_BYTES:
            view.image = annotation.icon.image
            (view as? FlutterAnnotationView)?.stickyZPosition = annotation.zIndex
        case .MARKER:
            if #available(iOS 11.0, *) {
                (view as? FlutterMarkerAnnotationView)?.stickyZPosition = annotation.zIndex
            }
        case .PIN:
            view.layer.zPosition = annotation.zIndex
        }
    }

    func getAnnotationView(annotation: FlutterAnnotation) -> MKAnnotationView {
        let identifier: String = self.reuseIdentifier(for: annotation)
        var annotationView = self.mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
        if annotationView == nil {
            if #available(iOS 11.0, *), annotation.icon.iconType == IconType.MARKER {
                annotationView = getMarkerAnnotationView(annotation: annotation, id: identifier)
            } else if annotation.icon.iconType == .CUSTOM_FROM_ASSET || annotation.icon.iconType == .CUSTOM_FROM_BYTES {
                annotationView = getCustomAnnotationView(annotation: annotation, id: identifier)
            } else {
                annotationView = getPinAnnotationView(annotation: annotation, id: identifier)
            }
        }
        guard let annotationView = annotationView else {
            return FlutterAnnotationView()
        }
        annotationView.annotation = annotation
        // Recycled views still carry the previous annotation's image/z-position,
        // so refresh them on every call rather than only at creation.
        self.applyAppearance(to: annotationView, annotation: annotation)
        // If annotation is not visible set alpha to 0 and don't let the user interact with it
        if !(annotation.isVisible ?? true) {
            annotationView.canShowCallout = false
            annotationView.alpha = CGFloat(0.0)
            annotationView.isDraggable = false
            return annotationView
        }
        if annotation.icon.iconType != .MARKER {
            self.initInfoWindow(annotation: annotation, annotationView: annotationView)
            if annotation.icon.iconType != .PIN {
                let x = (0.5 - annotation.anchor.x) * Double(annotationView.frame.size.width)
                let y = (0.5 - annotation.anchor.y) * Double(annotationView.frame.size.height)
                annotationView.centerOffset = CGPoint(x: x, y: y)
            }
        }
        annotationView.canShowCallout = true
        annotationView.alpha = CGFloat(annotation.alpha ?? 1.00)
        annotationView.isDraggable = annotation.isDraggable ?? false

        if #available(iOS 11.0, *) {
            annotationView.clusteringIdentifier = annotation.clusteringIdentifier
        }

        applyStackBadge(to: annotationView, count: annotation.stackCount)

        return annotationView
    }

    /// Adds (or removes) a small numeric badge in the upper-right of the
    /// annotation view to indicate a stack of N items sharing the same
    /// coordinate. Idempotent + reuse-safe — the badge is tagged so reused
    /// views drop the previous one before adding the new one.
    private func applyStackBadge(to view: MKAnnotationView, count: Int) {
        let badgeTag = 0x5741434B // arbitrary unique tag for the badge
        if let existing = view.viewWithTag(badgeTag) {
            existing.removeFromSuperview()
        }
        guard count > 1 else { return }

        let badge = UIView()
        badge.tag = badgeTag
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 7
        badge.isUserInteractionEnabled = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = count >= 100 ? "99+" : "\(count)"
        label.textColor = .white
        label.font = .systemFont(ofSize: 10, weight: .heavy)
        label.textAlignment = .center
        badge.addSubview(label)

        view.addSubview(badge)

        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            // MKPinAnnotationView renders its pin head *above* the view's
            // topAnchor (the view's bounds line up with the pin's tip /
            // shoulder). Push the badge above the topAnchor so it overlays
            // the upper-right of the head rather than the base of the stem.
            badge.centerYAnchor.constraint(equalTo: view.topAnchor, constant: -8),
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            label.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: badge.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.trailingAnchor, constant: -3),
        ])
    }

    func annotationsToAdd(annotations: NSArray) {
        for annotation in annotations {
            let annotationData: Dictionary<String, Any> = annotation as! Dictionary<String, Any>
            addAnnotation(annotationData: annotationData)
        }
    }

    func annotationsToChange(annotations: NSArray) {
        for annotation in annotations {
            let annotationData: Dictionary<String, Any> = annotation as! Dictionary<String, Any>
            guard let id = annotationData["annotationId"] as? String,
                  let annotationToChange = self.annotationsById[id] else {
                continue
            }
            let newAnnotation = FlutterAnnotation.init(fromDictionary: annotationData, registrar: registrar)
            if annotationToChange != newAnnotation {
                if !annotationToChange.wasDragged {
                    updateAnnotation(annotation: newAnnotation)
                } else {
                    annotationToChange.wasDragged = false
                }
            }
        }
    }

    func annotationsIdsToRemove(annotationIds: NSArray) {
        var toRemove: [FlutterAnnotation] = []
        toRemove.reserveCapacity(annotationIds.count)
        for annotationId in annotationIds {
            guard let id = annotationId as? String,
                  let annotation = self.annotationsById.removeValue(forKey: id) else {
                continue
            }
            toRemove.append(annotation)
        }
        if !toRemove.isEmpty {
            self.mapView.removeAnnotations(toRemove)
        }
    }

    func removeAllAnnotations() {
        self.mapView.removeAnnotations(self.mapView.annotations)
        self.annotationsById.removeAll()
        self.maxAnnotationZIndex = -1
    }

    func onAnnotationClick(annotation: MKAnnotation) {
        if let flutterAnnotation: FlutterAnnotation = annotation as? FlutterAnnotation {
            flutterAnnotation.wasDragged = true
            channel.invokeMethod("annotation#onTap", arguments: ["annotationId" : flutterAnnotation.id])
        }
    }

    func selectAnnotation(with id: String) {
        if let annotation: FlutterAnnotation = self.getAnnotation(with: id) {
            annotation.selectedProgrammatically = true
            self.mapView.selectAnnotation(annotation, animated: true)
        }
    }

    func hideAnnotation(with id: String) {
        if let annotation: FlutterAnnotation = self.getAnnotation(with: id) {
            self.mapView.deselectAnnotation(annotation, animated: true)
        }
    }

    func isAnnotationSelected(with id: String) -> Bool {
        guard let annotation = self.annotationsById[id] else { return false }
        return self.mapView.selectedAnnotations.contains(where: { ($0 as? FlutterAnnotation) === annotation })
    }


    private func removeAnnotation(id: String) {
        if let flutterAnnotation = self.annotationsById.removeValue(forKey: id) {
            self.mapView.removeAnnotation(flutterAnnotation)
        }
    }

    private func initInfoWindow(annotation: FlutterAnnotation, annotationView: MKAnnotationView) {
        // MKPinAnnotationView (.PIN) is the leaning teardrop pin: its tip (the
        // coordinate) sits left of the view's horizontal center, and MapKit
        // ships a default calloutOffset that compensates so the bubble points
        // at the tip. Overriding it — even to zero — drops that compensation
        // and nudges the callout ~8pt right. So only set our own offset for the
        // symmetric custom-image / marker views, whose point is centered.
        if annotation.icon.iconType != .PIN {
            let x = self.getInfoWindowXOffset(annotationView: annotationView, annotation: annotation)
            let y = self.getInfoWindowYOffset(annotationView: annotationView, annotation: annotation)
            annotationView.calloutOffset = CGPoint(x: x, y: y)
        }
        guard #available(iOS 9.0, *), let subtitle = annotation.subtitle, !subtitle.isEmpty else {
            // Clear any accessory left over from a previously recycled view so a
            // reused annotation doesn't show the prior one's snippet.
            annotationView.detailCalloutAccessoryView = nil
            return
        }

        // Constrain the callout subtitle so long single-line snippets (e.g.
        // unspaced rune strings or transliterations) wrap to a second line
        // instead of stretching the callout off-screen. Truncates at the
        // tail after two lines.
        let label = UILabel()
        label.text = subtitle
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: UIFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        let maxWidth: CGFloat = 160 // ~20 characters at the system small font
        label.preferredMaxLayoutWidth = maxWidth
        label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        annotationView.detailCalloutAccessoryView = label
    }

    @objc func onCalloutTapped(infoWindowTap: InfoWindowTapGestureRecognizer) {
        if infoWindowTap.annotationId != nil && self.currentlySelectedAnnotation == infoWindowTap.annotationId! {
            self.channel.invokeMethod("infoWindow#onTap", arguments: ["annotationId": infoWindowTap.annotationId])
        }
        if infoWindowTap.annotationView != nil && self.currentlySelectedAnnotation != infoWindowTap.annotationId! {
            infoWindowTap.annotationView?.removeGestureRecognizer(infoWindowTap)
        }
    }

    private func getAnnotation(with id: String) -> FlutterAnnotation? {
        return self.annotationsById[id]
    }

    private func annotationExists(with id: String) -> Bool {
        return self.annotationsById[id] != nil
    }

    private func addAnnotation(annotationData: Dictionary<String, Any>) {
        let annotation: FlutterAnnotation = FlutterAnnotation(fromDictionary: annotationData, registrar: registrar)
        self.addAnnotation(annotation: annotation)
    }

    /**
     Checks if an Annotation with the same id exists and removes it before adding if necessary
     - Parameter annotation: the FlutterAnnotation that should be added
     */
    private func addAnnotation(annotation: FlutterAnnotation) {
        if let id = annotation.id, self.annotationsById[id] != nil {
            self.removeAnnotation(id: id)
        }
        if annotation.zIndex == -1 {
            annotation.zIndex = self.getNextAnnotationZIndex()
            channel.invokeMethod("annotation#onZIndexChanged", arguments: ["annotationId": annotation.id!, "zIndex": annotation.zIndex])
        }
        if annotation.zIndex > self.maxAnnotationZIndex {
            self.maxAnnotationZIndex = annotation.zIndex
        }
        if let id = annotation.id {
            self.annotationsById[id] = annotation
        }
        self.mapView.addAnnotation(annotation)
    }

    private func updateAnnotation(annotation: FlutterAnnotation) {
        if let oldAnnotation = self.getAnnotation(with: annotation.id) {
            UIView.animate(withDuration: 0.32, animations: {
                oldAnnotation.coordinate = annotation.coordinate
                oldAnnotation.zIndex = annotation.zIndex
                oldAnnotation.anchor = annotation.anchor
                oldAnnotation.alpha = annotation.alpha
                oldAnnotation.isVisible = annotation.isVisible
                oldAnnotation.title = annotation.title
                oldAnnotation.subtitle = annotation.subtitle
            })
            
            // Update the annotation view with the new image
            if let view = self.mapView.view(for: oldAnnotation) {
                let newAnnotationView = getAnnotationView(annotation: annotation)
                view.image = newAnnotationView.image
            }
        }
    }

    private func getNextAnnotationZIndex() -> Double {
        if self.annotationsById.isEmpty {
            return 0
        }
        return self.maxAnnotationZIndex + 1
    }

    private func isAnnotationInFront(zIndex: Double) -> Bool {
        return self.maxAnnotationZIndex == zIndex
    }

    private func getPinAnnotationView(annotation: FlutterAnnotation, id: String) -> MKPinAnnotationView {
        var pinAnnotationView: MKPinAnnotationView
        if #available(iOS 11.0, *) {
            self.mapView.register(MKPinAnnotationView.self, forAnnotationViewWithReuseIdentifier: id)
            pinAnnotationView = self.mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation) as! MKPinAnnotationView
        } else {
            pinAnnotationView = MKPinAnnotationView.init(annotation: annotation, reuseIdentifier: id)
        }
        pinAnnotationView.layer.zPosition = annotation.zIndex

        if let hueColor: Double = annotation.icon.hueColor {
            pinAnnotationView.pinTintColor = UIColor.init(hue: hueColor, saturation: 1, brightness: 1, alpha: 1)
        }

        return pinAnnotationView
    }

    @available(iOS 11.0, *)
    private func getMarkerAnnotationView(annotation: FlutterAnnotation, id: String) -> FlutterMarkerAnnotationView {
        self.mapView.register(FlutterMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: id)
        let markerAnnotationView: FlutterMarkerAnnotationView = self.mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation) as! FlutterMarkerAnnotationView
        markerAnnotationView.stickyZPosition = annotation.zIndex

        if let hueColor: Double = annotation.icon.hueColor {
            markerAnnotationView.markerTintColor = UIColor.init(hue: hueColor, saturation: 1, brightness: 1, alpha: 1)
        }

        return markerAnnotationView
    }

    private func getCustomAnnotationView(annotation: FlutterAnnotation, id: String) -> FlutterAnnotationView {
        let annotationView: FlutterAnnotationView
        if #available(iOS 11.0, *) {
            self.mapView.register(FlutterAnnotationView.self, forAnnotationViewWithReuseIdentifier: id)
            annotationView = self.mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation) as! FlutterAnnotationView
        } else {
            annotationView = FlutterAnnotationView(annotation: annotation, reuseIdentifier: id)
        }
        annotationView.image = annotation.icon.image
        annotationView.stickyZPosition = annotation.zIndex
        return annotationView
    }

    private func getInfoWindowXOffset(annotationView: MKAnnotationView, annotation: FlutterAnnotation) -> CGFloat {
        // MapKit interprets calloutOffset relative to the annotation view
        // (zero = callout centered above the pin), so it must depend only on
        // the view's own width and the requested anchor — never on the view's
        // on-screen origin. The previous formula added frame.origin.x, which
        // shoved the callout east by the pin's screen X (the further right the
        // pin sat, the larger the skew). The default anchor.x of 0.5 yields a
        // zero offset, i.e. centered above the pin.
        return (CGFloat(annotation.calloutOffset.x) - 0.5) * annotationView.frame.width
    }

    private func getInfoWindowYOffset(annotationView: MKAnnotationView, annotation: FlutterAnnotation) -> CGFloat {
        return annotationView.frame.height * CGFloat(annotation.calloutOffset.y)
    }

    private func moveToFront(annotation: FlutterAnnotation) {
        let id: String = annotation.id
        annotation.zIndex = self.getNextAnnotationZIndex()
        channel.invokeMethod("annotation#onZIndexChanged", arguments: ["annotationId": id, "zIndex": annotation.zIndex])
        self.addAnnotation(annotation: annotation)
        self.selectAnnotation(with: id)
    }
}

class InfoWindowTapGestureRecognizer: UITapGestureRecognizer {
    var annotationView: UIView?
    var annotationId: String?
}
