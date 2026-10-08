//
//  FileBrowser.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-07.
//
import UIKit

class FileBrowser: UIViewController {
    @IBOutlet weak var fileCollectionView: UICollectionView!
    @IBOutlet weak var breadcrumbCollectionView: UICollectionView!
    @IBOutlet weak var backButton: UIBarButtonItem!
    @IBOutlet weak var itemCountLabel: UILabel!

    @IBAction func goToParentDirectory(_ sender: UIBarButtonItem) {
    }

    @IBAction func importFile(_ sender: UIBarButtonItem) {
    }

    @IBAction func unwindToBrowserFromViewer(_ segue: UIStoryboardSegue) {
    }
}
