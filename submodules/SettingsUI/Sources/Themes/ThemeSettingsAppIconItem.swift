import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AppBundle

private func generateBorderImage(theme: PresentationTheme, bordered: Bool, selected: Bool) -> UIImage? {
    return generateImage(CGSize(width: 30.0, height: 30.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)

        let lineWidth: CGFloat
        if selected {
            var accentColor = theme.list.itemAccentColor
            if accentColor.rgb == 0xffffff {
                accentColor = UIColor(rgb: 0x999999)
            }
            context.setStrokeColor(accentColor.cgColor)
            lineWidth = 2.0 - UIScreenPixel
        } else {
            context.setStrokeColor(theme.list.disclosureArrowColor.withAlphaComponent(0.4).cgColor)
            lineWidth = 1.0 - UIScreenPixel
        }

        if bordered || selected {
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: bounds.insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0))
        }
    })?.stretchableImage(withLeftCapWidth: 15, topCapHeight: 15)
}

class ThemeSettingsAppIconItem: ListViewItem, ItemListItem {
    var sectionId: ItemListSectionId

    let theme: PresentationTheme
    let systemStyle: ItemListSystemStyle
    let icons: [PresentationAppIcon]
    let currentIconName: String?
    let updated: (PresentationAppIcon) -> Void
    let tag: ItemListItemTag?

    init(theme: PresentationTheme, systemStyle: ItemListSystemStyle, sectionId: ItemListSectionId, icons: [PresentationAppIcon], currentIconName: String?, updated: @escaping (PresentationAppIcon) -> Void, tag: ItemListItemTag? = nil) {
        self.theme = theme
        self.systemStyle = systemStyle
        self.icons = icons
        self.currentIconName = currentIconName
        self.updated = updated
        self.tag = tag
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = ThemeSettingsAppIconItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))

            node.contentSize = layout.contentSize
            node.insets = layout.insets

            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? ThemeSettingsAppIconItemNode {
                let makeLayout = nodeValue.asyncLayout()

                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }
}


private final class ThemeSettingsAppIconNode : ASDisplayNode {
    private let iconNode: ASImageNode
    private let overlayNode: ASImageNode
    private let textNode: ImmediateTextNode
    private var action: (() -> Void)?

    private let activateAreaNode: AccessibilityAreaNode


    override init() {
        self.iconNode = ASImageNode()
        self.iconNode.clipsToBounds = true
        self.iconNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: 63.0, height: 63.0))
        self.iconNode.isLayerBacked = true
        self.iconNode.cornerRadius = 15.0

        self.overlayNode = ASImageNode()
        self.overlayNode.frame = CGRect(origin: CGPoint(), size: CGSize(width: 63.0, height: 63.0))
        self.overlayNode.isLayerBacked = true


        self.textNode = ImmediateTextNode()
        self.textNode.isUserInteractionEnabled = false
        self.textNode.displaysAsynchronously = false

        self.activateAreaNode = AccessibilityAreaNode()
        self.activateAreaNode.accessibilityTraits = [.button]

        super.init()

        self.addSubnode(self.iconNode)
        self.addSubnode(self.overlayNode)
        self.addSubnode(self.textNode)
        self.addSubnode(self.activateAreaNode)
    }

    func setup(theme: PresentationTheme, icon: UIImage, title: NSAttributedString, bordered: Bool, selected: Bool, action: @escaping () -> Void) {
        self.iconNode.image = icon
        self.textNode.attributedText = title
        self.overlayNode.image = generateBorderImage(theme: theme, bordered: bordered, selected: selected)
        self.action = {
            action()
        }

        self.activateAreaNode.accessibilityLabel = title.string
        self.activateAreaNode.accessibilityTraits = selected ? [.button, .selected] : [.button]

        self.setNeedsLayout()
    }

    override func didLoad() {
        super.didLoad()

        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }

    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.action?()
        }
    }

    override func layout() {
        super.layout()

        let bounds = self.bounds
        let iconSize = CGSize(width: 63.0, height: 63.0)

        self.iconNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((bounds.width - iconSize.width) / 2.0), y: 13.0), size: iconSize)
        self.overlayNode.frame = self.iconNode.frame

        let textSize = self.textNode.updateLayout(CGSize(width: bounds.size.width + 8.0, height: bounds.size.height))
        let textFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((bounds.width - textSize.width) / 2.0), y: 81.0), size: textSize)
        self.textNode.frame = textFrame


        self.activateAreaNode.frame = bounds
    }
}


private let textFont = Font.regular(12.0)
private let selectedTextFont = Font.medium(12.0)

class ThemeSettingsAppIconItemNode: ListViewItemNode, ItemListItemNode {
    private let backgroundNode: ASDisplayNode
    private let highlightNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode

    private let containerNode: ASDisplayNode
    private var nodes: [ThemeSettingsAppIconNode] = []

    private var item: ThemeSettingsAppIconItem?
    private var layoutParams: ListViewItemLayoutParams?

    var tag: ItemListItemTag? {
        return self.item?.tag
    }


    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true

        self.highlightNode = ASDisplayNode()
        self.highlightNode.isLayerBacked = true

        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true

        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true

        self.maskNode = ASImageNode()

        self.containerNode = ASDisplayNode()

        super.init(layerBacked: false)

        self.addSubnode(self.containerNode)
    }

    public func displayHighlight() {
        if self.backgroundNode.supernode != nil {
            self.insertSubnode(self.highlightNode, aboveSubnode: self.backgroundNode)
        } else {
            self.insertSubnode(self.highlightNode, at: 0)
        }

        Queue.mainQueue().after(1.2, {
            self.highlightNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { _ in
                self.highlightNode.removeFromSupernode()
            })
        })
    }

    func asyncLayout() -> (_ item: ThemeSettingsAppIconItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let contentSize: CGSize
            let insets: UIEdgeInsets
            let separatorHeight = UIScreenPixel

            let nodeSize = CGSize(width: 74.0, height: 102.0)
            let height: CGFloat = nodeSize.height * ceil(CGFloat(item.icons.count) / 4.0) + 12.0

            contentSize = CGSize(width: params.width, height: height)
            insets = itemListNeighborsGroupedInsets(neighbors, params)

            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size

            return (layout, { [weak self] in
                if let strongSelf = self {
                    strongSelf.item = item
                    strongSelf.layoutParams = params

                    strongSelf.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                    strongSelf.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                    strongSelf.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                    strongSelf.highlightNode.backgroundColor = item.theme.list.itemSearchHighlightColor

                    if strongSelf.backgroundNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                    }
                    if strongSelf.topStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                    }
                    if strongSelf.bottomStripeNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                    }
                    if strongSelf.maskNode.supernode == nil {
                        strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                    }

                    let hasCorners = itemListHasRoundedBlockLayout(params)
                    var hasTopCorners = false
                    var hasBottomCorners = false
                    switch neighbors.top {
                        case .sameSection(false):
                            strongSelf.topStripeNode.isHidden = true
                        default:
                            hasTopCorners = true
                            strongSelf.topStripeNode.isHidden = hasCorners
                    }
                    let bottomStripeInset: CGFloat
                    let bottomStripeOffset: CGFloat
                    switch neighbors.bottom {
                        case .sameSection(false):
                            bottomStripeInset = params.leftInset + 16.0
                            bottomStripeOffset = -separatorHeight
                            strongSelf.bottomStripeNode.isHidden = false
                        default:
                            bottomStripeInset = 0.0
                            bottomStripeOffset = 0.0
                            hasBottomCorners = true
                            strongSelf.bottomStripeNode.isHidden = hasCorners
                    }

                    strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: hasTopCorners, bottom: hasBottomCorners, glass: item.systemStyle == .glass) : nil

                    strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                    strongSelf.highlightNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                    strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                    strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                    strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: layoutSize.width - bottomStripeInset, height: separatorHeight))

                    strongSelf.containerNode.frame = CGRect(origin: CGPoint(x: params.leftInset, y: 2.0), size: CGSize(width: layoutSize.width - params.leftInset - params.rightInset, height: layoutSize.height))

                    let sideInset: CGFloat = 8.0
                    let spacing: CGFloat = floorToScreenPixels((params.width - sideInset * 2.0 - params.leftInset - params.rightInset - nodeSize.width * 4.0) / 3.0)
                    let verticalSpacing: CGFloat = 0.0

                    var x: CGFloat = sideInset
                    var y: CGFloat = 0.0

                    var i = 0
                    for icon in item.icons {
                        if i > 0 && i % 4 == 0 {
                            x = sideInset
                            y += nodeSize.height + verticalSpacing
                        }
                        let nodeFrame = CGRect(x: x, y: y, width: nodeSize.width, height: nodeSize.height)
                        x += nodeSize.width + spacing

                        let imageNode: ThemeSettingsAppIconNode
                        if strongSelf.nodes.count > i {
                            imageNode = strongSelf.nodes[i]
                        } else {
                            imageNode = ThemeSettingsAppIconNode()
                            strongSelf.nodes.append(imageNode)
                            strongSelf.containerNode.addSubnode(imageNode)
                        }

                        if let image = UIImage(named: icon.imageName, in: getAppBundle(), compatibleWith: nil) {
                            let selected = icon.name == item.currentIconName

                            imageNode.setup(theme: item.theme, icon: image, title: NSAttributedString(string: icon.name, font: selected ? selectedTextFont : textFont, textColor: selected  ? item.theme.list.itemAccentColor : item.theme.list.itemPrimaryTextColor, paragraphAlignment: .center), bordered: false, selected: selected, action: {
                                item.updated(icon)
                            })
                        }

                        imageNode.frame = nodeFrame

                        i += 1
                    }
                }
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
