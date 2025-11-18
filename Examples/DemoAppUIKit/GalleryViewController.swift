//
//  GalleryViewController.swift
//  AIAutoImageDemo
//

import UIKit
import AIAutoImage
internal import AIAutoImageCore

/// A view controller that displays a grid-based gallery of remote images.
///
/// Images are loaded asynchronously and processed using AIAutoImage.
/// Each thumbnail includes lightweight ML transformations such as:
/// - Content-aware saliency cropping
/// - Auto enhancement
///
/// Selecting a thumbnail navigates to the full-resolution product detail screen.
class GalleryViewController: UIViewController {

    /// A list of remote image URLs used to populate the gallery.
    ///
    /// These sample images demonstrate AIAutoImage's ability to load,
    /// transform, and display media directly from the network.
    private let images: [URL] = [
        URL(string: "https://picsum.photos/id/1001/800/800")!,
        URL(string: "https://picsum.photos/id/1003/800/800")!,
        URL(string: "https://picsum.photos/id/1015/800/800")!,
        URL(string: "https://picsum.photos/id/1020/800/800")!,
        URL(string: "https://picsum.photos/id/1035/800/800")!,
    ]

    /// The collection view used to display gallery images in a two-column grid layout.
    private let collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewFlowLayout()
    )

    /// Called after the view has been loaded into memory.
    ///
    /// Sets up UI appearance, configures the collection view,
    /// and prepares the controller for user interaction.
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "AI Gallery"
        view.backgroundColor = .systemBackground

        setupCollectionView()
    }

    /// Configures layout, positioning, and behavior of the gallery collection view.
    ///
    /// This includes:
    /// - Creating a two-column grid layout
    /// - Registering the custom thumbnail cell
    /// - Assigning data source and delegate
    /// - Adding the collection view to the view hierarchy
    private func setupCollectionView() {

        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: view.bounds.width / 2 - 16, height: 200)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)

        collectionView.collectionViewLayout = layout

        collectionView.register(
            ImageCell.self,
            forCellWithReuseIdentifier: ImageCell.identifier
        )

        collectionView.dataSource = self
        collectionView.delegate = self

        view.addSubview(collectionView)
        collectionView.frame = view.bounds
    }
}

// MARK: - UICollectionViewDataSource

extension GalleryViewController: UICollectionViewDataSource {

    /// Returns the number of images in the gallery.
    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        images.count
    }

    /// Creates and configures a cell for the given index path.
    ///
    /// - Parameters:
    ///   - collectionView: The collection view requesting the cell.
    ///   - indexPath: The position of the item.
    /// - Returns: A configured `ImageCell` for display.
    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ImageCell.identifier,
            for: indexPath
        ) as! ImageCell

        cell.configure(with: images[indexPath.item])
        return cell
    }
}

// MARK: - UICollectionViewDelegate

extension GalleryViewController: UICollectionViewDelegate {

    /// Handles tap selection of a gallery item.
    ///
    /// Navigates to `ProductViewController` to show the AI-enhanced full-screen image.
    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {

        navigationController?.pushViewController(
            ProductViewController(url: images[indexPath.item]),
            animated: true
        )
    }
}

// MARK: - Custom UICollectionViewCell

/// A custom collection view cell used to display a gallery thumbnail.
///
/// The cell uses `AIAutoImage` to load the remote image and apply
/// lightweight transformations optimized for grid previews.
class ImageCell: UICollectionViewCell {

    /// The reuse identifier for this cell type.
    static let identifier = "ImageCell"

    /// The image view displaying the processed thumbnail image.
    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.clipsToBounds = true
        iv.contentMode = .scaleAspectFill
        iv.layer.cornerRadius = 12
        return iv
    }()

    /// Initializes the cell and adds subviews.
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Updates the cell’s layout to fill the entire bounding area.
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    /// Configures the cell by loading the image from the given URL.
    ///
    /// - Parameter url: Remote image URL to load and process.
    ///
    /// The following AI transformations are applied:
    /// - Content-aware saliency cropping
    /// - Auto enhancement
    func configure(with url: URL) {
                
        imageView.ai_setImage(
            url: url,
            placeholder: UIImage(systemName: "photo"),
            transformations: [
                .contentAwareCrop(.saliency), // Smart cropping based on subject detection
                .autoEnhance                   // Improve basic color + tone
            ],
            context: .listItem                // Optimized for grid thumbnails
        )
    }
}
