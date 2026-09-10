import UIKit
import WebKit

/// Holds the reader's web view with the page-curl layer stacked above it.
final class ReaderCanvasView: UIView {
    let webView: WKWebView
    /// Called once the canvas is in a window, so the curl layer can join the
    /// view controller hierarchy.
    var onMoveToWindow: (() -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews { subview.frame = bounds }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    /// The view controller whose view contains this canvas.
    var hostViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// A page curl you drag with your finger, in the manner of Apple Books.
///
/// WebKit can't curl live content, so turns run on snapshots. While idle the
/// live web view is on screen and images of the current page and both of its
/// neighbours are kept ready. A drag, or a tap on a side of the page, reveals a
/// `UIPageViewController` curling those images; when the curl lands the web view
/// is moved to the new page underneath and the curl layer is hidden again.
///
/// In a two-page spread the layer uses a middle spine and curls one page at a
/// time, with each spread's snapshot cut into its left and right pages.
@MainActor
final class PageCurlController: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    private enum Slot { case previous, current, next }
    private enum Side { case full, left, right }

    /// One page (or half of a spread) shown as an image.
    private final class PageImageController: UIViewController {
        let slot: Slot
        let side: Side
        private let image: UIImage?
        private let background: UIColor

        init(image: UIImage?, background: UIColor, slot: Slot, side: Side) {
            self.image = image
            self.background = background
            self.slot = slot
            self.side = side
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func loadView() {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            // A missing image is the page beyond a chapter break, which appears
            // once the next chapter has loaded.
            imageView.backgroundColor = background
            view = imageView
        }
    }

    private weak var model: ReflowableReaderModel?
    private weak var canvas: ReaderCanvasView?
    private var pager: UIPageViewController?
    private var pagerShowsSpreads = false

    private var images: [Slot: UIImage] = [:]
    /// Snapshots match the reader's current page, so a curl can start.
    private var isReady = false
    private var isTurning = false
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    /// A tap that arrived while snapshots were still rendering.
    private var pendingTurn: Bool?

    func attach(to model: ReflowableReaderModel, canvas: ReaderCanvasView) {
        self.model = model
        self.canvas = canvas
        canvas.onMoveToWindow = { [weak self] in self?.adoptHost() }
        rebuildPager(spreads: false)
    }

    /// A page view controller only animates properly as a child of a view
    /// controller that is on screen.
    private func adoptHost() {
        guard let pager, pager.parent == nil, let host = canvas?.hostViewController else { return }
        host.addChild(pager)
        pager.didMove(toParent: host)
    }

    // MARK: - Reader hooks

    /// The page, layout, or document changed: render fresh snapshots shortly.
    func setNeedsRefresh() {
        guard !isTurning else { return }
        invalidate()
        let current = generation
        refreshTask = Task { [weak self] in
            // Jumps and relayouts report several positions in quick succession.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await self?.refresh(generation: current)
        }
    }

    /// Drops snapshots that no longer match the page, e.g. before a new chapter loads.
    func invalidate() {
        generation += 1
        isReady = false
        refreshTask?.cancel()
    }

    /// Animates a turn for a tap on a side of the page. Returns `false` when the
    /// curl is off, so the caller should turn the page directly.
    func turn(forward: Bool) -> Bool {
        guard let model, model.curlIsActive else { return false }
        guard !isTurning else { return true }
        guard isReady, let pager else {
            pendingTurn = forward
            return true
        }
        guard forward ? model.hasPageAfter : model.hasPageBefore else { return true }

        isTurning = true
        pager.view.isHidden = false
        pager.setViewControllers(pages(for: forward ? .next : .previous),
                                 direction: forward ? .forward : .reverse,
                                 animated: true) { [weak self] _ in
            guard let self else { return }
            self.isTurning = false
            self.finishTurn(forward: forward)
        }
        return true
    }

    // MARK: - Snapshots

    private func refresh(generation current: Int) async {
        guard let model else { return }
        guard model.curlIsActive else {
            pager?.view.isHidden = true
            pendingTurn = nil
            return
        }
        if model.isSpread != pagerShowsSpreads { rebuildPager(spreads: model.isSpread) }
        guard let pager else { return }

        let webView = model.webView
        let page = model.page
        let pageCount = model.pageCount

        guard let currentImage = await snapshot(of: webView), current == generation else { return }
        // Cover the live page with an identical image while its neighbours render.
        pager.setViewControllers(pages(for: .current, image: currentImage), direction: .forward, animated: false)
        pager.view.isHidden = false

        var nextImage: UIImage?
        var previousImage: UIImage?
        if page < pageCount - 1 {
            await model.showPage(page + 1)
            nextImage = await snapshot(of: webView)
        }
        if current == generation, page > 0 {
            await model.showPage(page - 1)
            previousImage = await snapshot(of: webView)
        }
        // Always put the web view back on the reader's page, even if a newer
        // refresh has taken over.
        await model.showPage(nil)
        guard current == generation else { return }

        images = [.current: currentImage]
        images[.next] = nextImage
        images[.previous] = previousImage
        isReady = true
        pager.view.isHidden = true

        if let forward = pendingTurn {
            pendingTurn = nil
            _ = turn(forward: forward)
        }
    }

    private func snapshot(of webView: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    private func finishTurn(forward: Bool) {
        isReady = false
        images = [:]
        // The layer keeps showing the new page until the web view has moved
        // there and fresh snapshots are ready.
        model?.curlDidTurn(forward: forward)
    }

    // MARK: - Pages

    private func rebuildPager(spreads: Bool) {
        guard let canvas else { return }
        if let pager {
            for recognizer in canvas.gestureRecognizers ?? [] where pager.gestureRecognizers.contains(recognizer) {
                canvas.removeGestureRecognizer(recognizer)
            }
            pager.willMove(toParent: nil)
            pager.view.removeFromSuperview()
            pager.removeFromParent()
        }

        let spine: UIPageViewController.SpineLocation = spreads ? .mid : .min
        let pager = UIPageViewController(transitionStyle: .pageCurl,
                                         navigationOrientation: .horizontal,
                                         options: [.spineLocation: NSNumber(value: spine.rawValue)])
        pager.isDoubleSided = spreads
        pager.dataSource = self
        pager.delegate = self
        pager.view.backgroundColor = .clear
        pager.view.isHidden = true
        // Touches pass through to the web view (links, selection, tap zones);
        // drags are picked up by the pan recognizer moved onto the canvas.
        pager.view.isUserInteractionEnabled = false
        canvas.addSubview(pager.view)

        self.pager = pager
        pagerShowsSpreads = spreads
        pager.setViewControllers(pages(for: .current), direction: .forward, animated: false)

        // The curl's own edge-tap recognizer is left behind: the reader's tap
        // zones already turn pages, and call `turn(forward:)` to animate.
        for recognizer in pager.gestureRecognizers where recognizer is UIPanGestureRecognizer {
            canvas.addGestureRecognizer(recognizer)
        }
        adoptHost()
    }

    private func pages(for slot: Slot, image: UIImage? = nil) -> [UIViewController] {
        let image = image ?? images[slot]
        let background = model?.pageBackground ?? .white
        guard pagerShowsSpreads else {
            return [PageImageController(image: image, background: background, slot: slot, side: .full)]
        }
        let halves = image.map(Self.halves(of:))
        return [
            PageImageController(image: halves?.left, background: background, slot: slot, side: .left),
            PageImageController(image: halves?.right, background: background, slot: slot, side: .right),
        ]
    }

    /// A spread is laid out with equal outer margins and a centered gutter, so
    /// cutting it down the middle gives two symmetrical pages.
    private static func halves(of image: UIImage) -> (left: UIImage?, right: UIImage?) {
        guard let cgImage = image.cgImage else { return (nil, nil) }
        let half = cgImage.width / 2
        let left = cgImage.cropping(to: CGRect(x: 0, y: 0, width: half, height: cgImage.height))
        let right = cgImage.cropping(to: CGRect(x: half, y: 0, width: cgImage.width - half, height: cgImage.height))
        return (left.map { UIImage(cgImage: $0, scale: image.scale, orientation: .up) },
                right.map { UIImage(cgImage: $0, scale: image.scale, orientation: .up) })
    }

    // MARK: - UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard isReady, !isTurning || pagerShowsSpreads, let model, model.hasPageAfter,
              let page = viewController as? PageImageController else { return nil }
        switch (page.slot, page.side) {
        case (.current, .full), (.current, .right): return pages(for: .next).first
        case (.next, .left): return pages(for: .next).last
        default: return nil
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard isReady, !isTurning || pagerShowsSpreads, let model, model.hasPageBefore,
              let page = viewController as? PageImageController else { return nil }
        switch (page.slot, page.side) {
        case (.current, .full): return pages(for: .previous).first
        case (.current, .left): return pages(for: .previous).last
        case (.previous, .right): return pages(for: .previous).first
        default: return nil
        }
    }

    // MARK: - UIPageViewControllerDelegate

    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        isTurning = true
        pageViewController.view.isHidden = false
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        isTurning = false
        guard completed else {
            // The page was let go and fell back: the live page never moved.
            pageViewController.view.isHidden = true
            return
        }
        let landedOn = (pageViewController.viewControllers?.first as? PageImageController)?.slot
        finishTurn(forward: landedOn == .next)
    }
}
