import DesignSystem
import EmojiText
import Env
import Foundation
import Models
import Network
import Shimmer
import SwiftUI

@MainActor
public struct StatusRowView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.isInCaptureMode) private var isInCaptureMode: Bool
  @Environment(\.redactionReasons) private var reasons
  @Environment(\.isCompact) private var isCompact: Bool
  @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
  @Environment(\.isStatusFocused) private var isFocused
  @Environment(\.indentationLevel) private var indentationLevel

  @Environment(QuickLook.self) private var quickLook
  @Environment(Theme.self) private var theme

  @State private var viewModel: StatusRowViewModel
  @State private var showSelectableText: Bool = false

  public init(viewModel: StatusRowViewModel) {
    _viewModel = .init(initialValue: viewModel)
  }

  var contextMenu: some View {
    StatusRowContextMenu(viewModel: viewModel, showTextForSelection: $showSelectableText)
  }

  public var body: some View {
    HStack(spacing: 0) {
      if !isCompact {
        HStack(spacing: 3) {
          ForEach(0 ..< indentationLevel, id: \.self) { level in
            Rectangle()
              .fill(theme.tintColor)
              .frame(width: 2)
              .accessibilityHidden(true)
              .opacity((indentationLevel == level + 1) ? 1 : 0.15)
          }
        }
        if indentationLevel > 0 {
          Spacer(minLength: 8)
        }
      }
      VStack(alignment: .leading, spacing: .statusComponentSpacing) {
        if viewModel.isFiltered, let filter = viewModel.filter {
          switch filter.filter.filterAction {
          case .warn:
            makeFilterView(filter: filter.filter)
          case .hide:
            EmptyView()
          }
        } else {
          if !isCompact {
            Group {
              StatusRowTagView(viewModel: viewModel)
              StatusRowReblogView(viewModel: viewModel)
              StatusRowReplyView(viewModel: viewModel)
            }
            .padding(.leading, theme.avatarPosition == .top ? 0 : AvatarView.FrameConfig.status.width + .statusColumnsSpacing)
          }
          HStack(alignment: .top, spacing: .statusColumnsSpacing) {
            if !isCompact,
               theme.avatarPosition == .leading
            {
              Button {
                viewModel.navigateToAccountDetail(account: viewModel.finalStatus.account)
              } label: {
                AvatarView(viewModel.finalStatus.account.avatar)
              }
            }
            VStack(alignment: .leading, spacing: .statusComponentSpacing) {
              if !isCompact {
                StatusRowHeaderView(viewModel: viewModel)
              }
              StatusRowContentView(viewModel: viewModel)
                .contentShape(Rectangle())
                .onTapGesture {
                  guard !isFocused else { return }
                  viewModel.navigateToDetail()
                }
                .accessibilityActions {
                  if isFocused, viewModel.showActions {
                    accessibilityActions
                  }
                }
              if !reasons.contains(.placeholder),
                  viewModel.showActions, isFocused || theme.statusActionsDisplay != .none,
                 !isInCaptureMode {
                StatusRowActionsView(viewModel: viewModel)
                  .tint(isFocused ? theme.tintColor : .gray)
                  .contentShape(Rectangle())
              }

              if isFocused, !isCompact {
                StatusRowDetailView(viewModel: viewModel)
              }
            }
          }
        }
      }
    }
    .onAppear {
      viewModel.markSeen()
      if !reasons.contains(.placeholder) {
        if !isCompact, viewModel.embeddedStatus == nil {
          Task {
            await viewModel.loadEmbeddedStatus()
          }
        }
      }
    }
    .contextMenu {
      contextMenu
        .onAppear {
          Task {
            await viewModel.loadAuthorRelationship()
          }
        }
    }
    .swipeActions(edge: .trailing) {
      // The actions associated with the swipes are exposed as custom accessibility actions and there is no way to remove them.
      if !isCompact, accessibilityVoiceOverEnabled == false {
        StatusRowSwipeView(viewModel: viewModel, mode: .trailing)
      }
    }
    .swipeActions(edge: .leading) {
      // The actions associated with the swipes are exposed as custom accessibility actions and there is no way to remove them.
      if !isCompact, accessibilityVoiceOverEnabled == false {
        StatusRowSwipeView(viewModel: viewModel, mode: .leading)
      }
    }
    #if os(visionOS)
    .listRowBackground(RoundedRectangle(cornerRadius: 8)
      .foregroundStyle(Material.regular))
    .listRowHoverEffect(.lift)
    #else
    .listRowBackground(viewModel.highlightRowColor)
    #endif
    .listRowInsets(.init(top: 12,
                         leading: .layoutPadding,
                         bottom: 6,
                         trailing: .layoutPadding))
    .accessibilityElement(children: isFocused ? .contain : .combine)
    .accessibilityLabel(isFocused == false && accessibilityVoiceOverEnabled
      ? StatusRowAccessibilityLabel(viewModel: viewModel).finalLabel() : Text(""))
    .accessibilityHidden(viewModel.filter?.filter.filterAction == .hide)
    .accessibilityAction {
      guard !isFocused else { return }
      viewModel.navigateToDetail()
    }
    .accessibilityActions {
      if !isFocused, viewModel.showActions, accessibilityVoiceOverEnabled {
        accessibilityActions
      }
    }
    .background {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
          guard !isFocused else { return }
          viewModel.navigateToDetail()
        }
    }
    .overlay {
      if viewModel.isLoadingRemoteContent {
        remoteContentLoadingView
      }
    }
    .alert(isPresented: $viewModel.showDeleteAlert, content: {
      Alert(
        title: Text("status.action.delete.confirm.title"),
        message: Text("status.action.delete.confirm.message"),
        primaryButton: .destructive(
          Text("status.action.delete"))
        {
          Task {
            await viewModel.delete()
          }
        },
        secondaryButton: .cancel()
      )
    })
    .alignmentGuide(.listRowSeparatorLeading) { _ in
      -100
    }
    .sheet(isPresented: $showSelectableText) {
      let content = viewModel.status.reblog?.content.asSafeMarkdownAttributedString ?? viewModel.status.content.asSafeMarkdownAttributedString
      SelectTextView(content: content)
    }
    .environment(
      StatusDataControllerProvider.shared.dataController(for: viewModel.finalStatus,
                                                         client: viewModel.client)
    )
  }

  @ViewBuilder
  private var accessibilityActions: some View {
    // Add reply and quote, which are lost when the swipe actions are removed
    Button("status.action.reply") {
      HapticManager.shared.fireHaptic(.notification(.success))
      viewModel.routerPath.presentedSheet = .replyToStatusEditor(status: viewModel.status)
    }

    Button("settings.swipeactions.status.action.quote") {
      HapticManager.shared.fireHaptic(.notification(.success))
      viewModel.routerPath.presentedSheet = .quoteStatusEditor(status: viewModel.status)
    }
    .disabled(viewModel.status.visibility == .direct || viewModel.status.visibility == .priv)

    if viewModel.finalStatus.mediaAttachments.isEmpty == false {
      Button("accessibility.status.media-viewer-action.label") {
        HapticManager.shared.fireHaptic(.notification(.success))
        let attachments = viewModel.finalStatus.mediaAttachments
        #if targetEnvironment(macCatalyst)
          openWindow(value: WindowDestinationMedia.mediaViewer(
            attachments: attachments,
            selectedAttachment: attachments[0]
          ))
        #else
          quickLook.prepareFor(selectedMediaAttachment: attachments[0], mediaAttachments: attachments)
        #endif
      }
    }

    Button(viewModel.displaySpoiler ? "status.show-more" : "status.show-less") {
      withAnimation {
        viewModel.displaySpoiler.toggle()
      }
    }

    Button("@\(viewModel.status.account.username)") {
      HapticManager.shared.fireHaptic(.notification(.success))
      viewModel.routerPath.navigate(to: .accountDetail(id: viewModel.status.account.id))
    }

    // Add a reference to the post creator
    if viewModel.status.account != viewModel.finalStatus.account {
      Button("@\(viewModel.finalStatus.account.username)") {
        HapticManager.shared.fireHaptic(.notification(.success))
        viewModel.routerPath.navigate(to: .accountDetail(id: viewModel.finalStatus.account.id))
      }
    }

    // Add in each detected link in the content
    ForEach(viewModel.finalStatus.content.links) { link in
      switch link.type {
      case .url:
        if UIApplication.shared.canOpenURL(link.url) {
          Button("accessibility.tabs.timeline.content-link-\(link.title)") {
            HapticManager.shared.fireHaptic(.notification(.success))
            _ = viewModel.routerPath.handle(url: link.url)
          }
        }
      case .hashtag:
        Button("accessibility.tabs.timeline.content-hashtag-\(link.title)") {
          HapticManager.shared.fireHaptic(.notification(.success))
          _ = viewModel.routerPath.handle(url: link.url)
        }
      case .mention:
        Button("\(link.title)") {
          HapticManager.shared.fireHaptic(.notification(.success))
          _ = viewModel.routerPath.handle(url: link.url)
        }
      }
    }
  }

  private func makeFilterView(filter: Filter) -> some View {
    HStack {
      Text("status.filter.filtered-by-\(filter.title)")
      Button {
        withAnimation {
          viewModel.isFiltered = false
        }
      } label: {
        Text("status.filter.show-anyway")
          .foregroundStyle(theme.tintColor)
      }
      .buttonStyle(.plain)
    }
    .onTapGesture {
      withAnimation {
        viewModel.isFiltered = false
      }
    }
    .accessibilityAction {
      viewModel.isFiltered = false
    }
  }

  private var remoteContentLoadingView: some View {
    ZStack(alignment: .center) {
      VStack {
        Spacer()
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        Spacer()
      }
    }
    .background(Color.black.opacity(0.40))
    .transition(.opacity)
  }
}

